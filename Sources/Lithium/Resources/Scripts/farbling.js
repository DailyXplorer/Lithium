// Brave-style farbling: tiny, deterministic noise per (session, site) so fingerprints
// stay stable on one site but cannot be linked across sites or sessions.
// WebKit's own fingerprinting protections run underneath (see Privacy.swift); this covers
// what they leave: audio, WebGL and offscreen reads, CPU count, voices, and same-origin iframes.
// Not workers: WebKit injects user scripts into documents only, and running a worker from a blob
// that imports the page's script breaks relative URLs, CSPs and SharedWorker sharing.
(() => {
  'use strict';
  // A frame or popup keeps its initial blank window when its first page is of the same origin
  // (HTML's window reuse), so nothing in that window can be trusted. The copy that protected it
  // left this function there (see `protect`) to look after the new document instead. Its name is
  // keyed per launch so a page can't guess or forge it.
  const ADOPT = '__LITHIUM_ADOPT__';
  const adopter = window[ADOPT];
  if (typeof adopter === 'function') { adopter(document); return; }
  // Keyed hash of the top page's site (see Privacy.farbling).
  const SEED = '__LITHIUM_SEED__';
  // One per launch key, not per site, so a popup and the cross-site frame that opened it agree.
  const MARK = '__LITHIUM_MARK__';
  const MAX_PIXELS = 500000;
  // Taken once: the page shares this world and could replace any of them to skip protection or
  // skew the noise.
  const apply = Reflect.apply;
  const { hasOwn, defineProperty, getOwnPropertyDescriptor, freeze } = Object;
  const sourceText = Function.prototype.toString;
  const { imul, floor, ceil, max, min, trunc } = Math;
  const BigIntCtor = BigInt, { asIntN } = BigInt, NumberCtor = Number, { isFinite } = Number;
  const WeakMapCtor = WeakMap, WeakSetCtor = WeakSet;
  const weakMapGet = WeakMap.prototype.get;
  const weakMapSet = WeakMap.prototype.set;
  const weakSetHas = WeakSet.prototype.has;
  const weakSetAdd = WeakSet.prototype.add;
  // What a proxy of a window does without a trap of the page's (see `shield`).
  const TRAPS = ['getPrototypeOf', 'setPrototypeOf', 'isExtensible', 'preventExtensions', 'getOwnPropertyDescriptor',
    'defineProperty', 'has', 'get', 'set', 'deleteProperty', 'ownKeys'];
  const reflect = { __proto__: null };
  for (let i = 0; i < TRAPS.length; i++) reflect[TRAPS[i]] = Reflect[TRAPS[i]];
  const construct = Reflect.construct;
  // The canvas and array members the noise goes through, likewise. They work on objects of any
  // same-origin realm, so these serve the frames and popups too.
  const member = (proto, name) => (proto && getOwnPropertyDescriptor(proto, name)) || {};
  const read = (getter, self) => { try { return apply(getter, self, []); } catch (_) { return 0; } };
  const Uint8ArrayCtor = Uint8Array, { isView } = ArrayBuffer;
  const typedArray = Object.getPrototypeOf(Uint8Array.prototype);
  const typedLength = member(typedArray, 'length').get;
  const typedKind = member(typedArray, Symbol.toStringTag).get;
  const imageWidth = member(ImageData.prototype, 'width').get;
  const imageHeight = member(ImageData.prototype, 'height').get;
  const imageData = member(ImageData.prototype, 'data').get;
  const audioBufferLength = member(globalThis.AudioBuffer && AudioBuffer.prototype, 'length').get;
  const frequencyBinCount = member(globalThis.AnalyserNode && AnalyserNode.prototype, 'frequencyBinCount').get;
  const createElement = member(Document.prototype, 'createElement').value;
  const canvasWidth = member(HTMLCanvasElement.prototype, 'width');
  const canvasHeight = member(HTMLCanvasElement.prototype, 'height');
  const getContext = member(HTMLCanvasElement.prototype, 'getContext').value;
  const drawImage = member(CanvasRenderingContext2D.prototype, 'drawImage').value;
  const putImageData = member(CanvasRenderingContext2D.prototype, 'putImageData').value;
  const OffscreenCanvasCtor = globalThis.OffscreenCanvas;
  const offscreen = OffscreenCanvasCtor && OffscreenCanvasCtor.prototype;
  const offscreenWidth = member(offscreen, 'width').get;
  const offscreenHeight = member(offscreen, 'height').get;
  const offscreenGetContext = member(offscreen, 'getContext').value;
  const offscreenContext = globalThis.OffscreenCanvasRenderingContext2D && OffscreenCanvasRenderingContext2D.prototype;
  const offscreenDrawImage = member(offscreenContext, 'drawImage').value;
  const offscreenPutImageData = member(offscreenContext, 'putImageData').value;
  const glMembers = (context) => {
    const proto = context && context.prototype;
    return { __proto__: null, getParameter: member(proto, 'getParameter').value,
      isContextLost: member(proto, 'isContextLost').value, checkFramebufferStatus: member(proto, 'checkFramebufferStatus').value,
      drawingBufferWidth: member(proto, 'drawingBufferWidth').get, drawingBufferHeight: member(proto, 'drawingBufferHeight').get,
      getBufferParameter: member(proto, 'getBufferParameter').value, getBufferSubData: member(proto, 'getBufferSubData').value,
      bufferSubData: member(proto, 'bufferSubData').value };
  };
  const gl1 = glMembers(globalThis.WebGLRenderingContext), gl2 = glMembers(globalThis.WebGL2RenderingContext);
  const ourNavigator = navigator;
  const navigatorLanguage = member(Navigator.prototype, 'language').get;
  const voiceProto = globalThis.SpeechSynthesisVoice && SpeechSynthesisVoice.prototype;
  const voiceDefault = member(voiceProto, 'default').get;
  const voiceLocal = member(voiceProto, 'localService').get;
  const voiceLang = member(voiceProto, 'lang').get;
  const { toLowerCase, startsWith, indexOf, slice } = String.prototype;
  const { getPrototypeOf } = Object;
  const CustomEventCtor = CustomEvent;
  const eventDetail = member(CustomEvent.prototype, 'detail').get;
  const preventDefault = member(Event.prototype, 'preventDefault').value;
  const eventTarget = member(Event.prototype, 'target').get;
  const elementName = member(Element.prototype, 'localName').get;
  const firstElementChild = member(Element.prototype, 'firstElementChild').get;
  const querySelector = member(Element.prototype, 'querySelector').value;
  const addEventListener = member(EventTarget.prototype, 'addEventListener').value;
  const dispatchEvent = member(EventTarget.prototype, 'dispatchEvent').value;
  const nodeType = member(Node.prototype, 'nodeType').get;
  const parentNode = member(Node.prototype, 'parentNode').get;
  const documentView = member(Document.prototype, 'defaultView').get;
  // By node type: elements, documents, fragments and shadow roots.
  const queryAll = { __proto__: null,
    1: member(Element.prototype, 'querySelectorAll').value,
    9: member(Document.prototype, 'querySelectorAll').value,
    11: member(DocumentFragment.prototype, 'querySelectorAll').value };
  const nodeCount = member(NodeList.prototype, 'length').get;
  const iframeWindow = member(HTMLIFrameElement.prototype, 'contentWindow').get;
  const frameWindow = member(HTMLFrameElement.prototype, 'contentWindow').get;
  const trustedTypesFactory = globalThis.trustedTypes;
  const isTrustedHTML = trustedTypesFactory && member(TrustedTypePolicyFactory.prototype, 'isHTML').value;
  const trustedHTMLText = trustedTypesFactory && member(TrustedHTML.prototype, 'toString').value;
  const windowTrustedTypes = trustedTypesFactory && (member(globalThis, 'trustedTypes').get || member(Window.prototype, 'trustedTypes').get);
  const defaultPolicy = trustedTypesFactory && member(TrustedTypePolicyFactory.prototype, 'defaultPolicy').get;
  const createHTML = trustedTypesFactory && member(TrustedTypePolicy.prototype, 'createHTML').value;
  const readyState = member(Document.prototype, 'readyState').get;
  const currentScript = member(Document.prototype, 'currentScript').get;
  const documentURL = member(Document.prototype, 'URL').get;
  const documentHead = member(Document.prototype, 'head').get;
  const regExpExec = RegExp.prototype.exec;
  const FRAME_TAG = /frame/i;
  // Documents with no response of their own, which take their creator's policies.
  const NO_RESPONSE = /^(about|blob|data):/i;
  const TRUSTED_TYPES_META = 'head meta[http-equiv="content-security-policy" i][content*="require-trusted-types-for" i]';
  // The head is the one place WebKit takes such a policy from.
  const hasTrustedTypesMeta = (doc) => {
    const head = read(documentHead, doc);
    return !!head && read(nodeCount, apply(queryAll[1], head, [TRUSTED_TYPES_META])) > 0;
  };

  // murmur3's finalizer: a cheap 32-bit mix in which every input bit moves every output bit.
  const fmix = (h) => {
    h = imul(h ^ (h >>> 16), 0x85ebca6b);
    h = imul(h ^ (h >>> 13), 0xc2b2ae35);
    return h ^ (h >>> 16);
  };

  const seedWords = [0, 8, 16, 24].map((at) => parseInt(SEED.slice(at, at + 8), 16) | 0);
  // A cross-origin frame mixes its origin in, so a tracker framed on a site farbles apart from the
  // site's own pages. `globalThis.origin`, as blank and srcdoc frames have "null" in `location`.
  // `ancestorOrigins`, as touching a cross-origin `top` would log an error.
  try {
    const ancestors = location.ancestorOrigins, origin = globalThis.origin;
    if (ancestors && ancestors.length && ancestors[ancestors.length - 1] !== origin) {
      let frame = 0x811c9dc5;
      for (let i = 0; i < origin.length; i++) frame = imul(frame ^ origin.charCodeAt(i), 0x01000193);
      for (let i = 0; i < 4; i++) seedWords[i] = fmix(seedWords[i] ^ frame ^ i);
    }
  } catch (_) {}

  // sfc32 over the seed's 128 bits: too much state to search from a few noisy samples.
  // The first outputs are dropped to spread the salt.
  const prng = (salt) => {
    let a = seedWords[0], b = seedWords[1], c = seedWords[2], d = seedWords[3] ^ salt;
    const next = () => {
      const t = (((a + b) | 0) + d) | 0;
      d = (d + 1) | 0;
      a = b ^ (b >>> 9);
      b = (c + (c << 3)) | 0;
      c = ((c << 21) | (c >>> 11)) + t | 0;
      return (t >>> 0) / 4294967296;
    };
    for (let i = 0; i < 12; i++) next();
    return next;
  };

  // Each pixel is decided from its spot in the canvas and its color, never from where the read
  // starts, so comparing small reads shows nothing. One color moves within a pair of values
  // (2k - o, 2k + 1 - o) and is decided on the pair, so noising twice changes nothing and pixels
  // never drift; for half the spots the pair straddles the low bits, so clearing them doesn't undo it.
  // Rows are `stride` bytes apart (WebGL can pad them). With a `step`, for reads past the limit,
  // only one pixel in `step` along a row is decided, staggered by row.
  const noisePixels = (data, left, top, width, height, start, stride = width * 4, step = 1) => {
    const kind = apply(typedKind, data, []);
    if (kind !== 'Uint8ClampedArray' && kind !== 'Uint8Array') return;
    for (let row = 0; row < height; row++) {
      const first = (step - (left + top + row) % step) % step;
      let at = start + row * stride + first * 4;
      const rowKey = fmix((top + row) ^ seedWords[1]) ^ seedWords[3];
      for (let column = first; column < width; column += step, at += 4 * step) {
        const spot = fmix(imul((left + column) ^ seedWords[0], 0x9e3779b1) ^ rowKey);
        const channel = (spot >>> 1) % 3, shift = spot >>> 31;
        const value = data[at + channel], pair = (value + shift) >> 1, low = 2 * pair - shift;
        // 0 and 255 have no pair when `o` is 1.
        if (low < 0 || low > 254) continue;
        const color = (data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24) ^ ((value ^ pair) << (channel << 3));
        const decision = fmix(color ^ spot ^ seedWords[2]);
        if ((decision & 0xffff) < 6554) data[at + channel] = low + ((decision >>> 16) & 1);
      }
    }
  };

  // Arguments are converted once, as the native call would: a value converting differently each
  // time could otherwise move the noise.
  const readImage = (target, self, args) => {
    if (args.length >= 4) for (let i = 0; i < 4; i++) args[i] = +args[i];
    const image = apply(target, self, args);
    const width = apply(imageWidth, image, []), height = apply(imageHeight, image, []);
    // A negative width or height reads that far back from the spot given.
    noisePixels(apply(imageData, image, []), (args[0] | 0) + min(args[2] | 0, 0), (args[1] | 0) + min(args[3] | 0, 0),
      width, height, 0, width * 4, ceil(width * height / MAX_PIXELS));
    return image;
  };

  // WebGL `readPixels` gets the same noise, on what it wrote only. Integer and float formats are
  // left exact, and so are reads of up to 16 pixels: most likely GPU picking, where a step of one
  // picks another object. A read that writes nothing (lost context, incomplete framebuffer) gets
  // no noise, nor do pixels past the edges. A bound framebuffer's size is unknown to WebGL, so only
  // its bottom left edges count.
  const GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401;
  const GL_PACK_ROW_LENGTH = 0x0D02, GL_PACK_SKIP_ROWS = 0x0D03, GL_PACK_SKIP_PIXELS = 0x0D04, GL_PACK_ALIGNMENT = 0x0D05;
  const GL_PIXEL_PACK_BUFFER_BINDING = 0x88ED, GL_FRAMEBUFFER = 0x8D40, GL_READ_FRAMEBUFFER = 0x8CA8, GL_FRAMEBUFFER_COMPLETE = 0x8CD5;
  const GL_FRAMEBUFFER_BINDING = 0x8CA6, GL_READ_FRAMEBUFFER_BINDING = 0x8CAA, GL_PIXEL_PACK_BUFFER = 0x88EB, GL_BUFFER_SIZE = 0x8764;
  // Arguments are converted once, as the native call would (see `readImage`). To WebGL2 an object
  // that isn't a typed array or DataView ([], {}, an ArrayBuffer) is an offset.
  const readPixelsArguments = (args, webgl2) => {
    if (args.length < 7) return;
    for (let i = 0; i < 6; i++) args[i] = i < 4 ? args[i] | 0 : args[i] >>> 0;
    if (args[6] && typeof args[6] === 'object' && (!webgl2 || isView(args[6]))) { if (args.length > 7) args[7] = args[7] >>> 0; }
    else if (webgl2 && args[6] != null) {
      const offset = +args[6];
      args[6] = NumberCtor(apply(asIntN, BigIntCtor, [64, BigIntCtor(isFinite(offset) ? trunc(offset) : 0)]));
    }
  };
  const readPixelsNoise = (gl, webgl2, self, args) => {
    const pixels = args[6], width = args[2], height = args[3];
    const packed = webgl2 && typeof pixels === 'number';
    if (args[4] !== GL_RGBA || args[5] !== GL_UNSIGNED_BYTE || !packed && (!pixels || typeof pixels !== 'object')) return;
    if (width <= 0 || height <= 0 || width * height <= 16) return;
    const parameter = (name) => apply(gl.getParameter, self, [name]);
    // WebGL1 has no offset: it ignores an 8th argument.
    let start = packed ? floor(pixels) : webgl2 && args.length > 7 ? floor(args[7]) || 0 : 0, stride, right = width, top = height, length;
    try {
      // A read into an array while a pack buffer is bound, or at an offset while none is, is an error.
      if (apply(gl.isContextLost, self, []) || (webgl2 && !parameter(GL_PIXEL_PACK_BUFFER_BINDING) !== !packed)) return;
      if (apply(gl.checkFramebufferStatus, self, [webgl2 ? GL_READ_FRAMEBUFFER : GL_FRAMEBUFFER]) !== GL_FRAMEBUFFER_COMPLETE) return;
      const alignment = parameter(GL_PACK_ALIGNMENT), rowLength = webgl2 ? parameter(GL_PACK_ROW_LENGTH) : 0;
      const skipPixels = webgl2 ? parameter(GL_PACK_SKIP_PIXELS) : 0;
      if (rowLength && rowLength < width + skipPixels) return;
      stride = ceil((rowLength || width) * 4 / alignment) * alignment;
      if (webgl2) start += parameter(GL_PACK_SKIP_ROWS) * stride + skipPixels * 4;
      if (!parameter(webgl2 ? GL_READ_FRAMEBUFFER_BINDING : GL_FRAMEBUFFER_BINDING)) {
        right = min(width, apply(gl.drawingBufferWidth, self, []) - args[0]);
        top = min(height, apply(gl.drawingBufferHeight, self, []) - args[1]);
      }
      length = packed ? apply(gl.getBufferParameter, self, [GL_PIXEL_PACK_BUFFER, GL_BUFFER_SIZE]) : read(typedLength, pixels);
    } catch (_) { return; }
    if (!(start >= 0) || start + (height - 1) * stride + width * 4 > length) return;
    const left = max(0, -args[0]), bottom = max(0, -args[1]);
    if (right <= left || top <= bottom) return;
    // Past the limit, a share of the pixels, counted on what the read covers of the canvas.
    const x = args[0] + left, y = args[1] + bottom, columns = right - left, rows = top - bottom;
    const step = ceil(columns * rows / MAX_PIXELS);
    start += bottom * stride + left * 4;
    if (!packed) { noisePixels(pixels, x, y, columns, rows, start, stride, step); return; }
    // Pack buffers are noised in place: noising `getBufferSubData` would miss other bindings.
    try {
      const copy = new Uint8ArrayCtor((rows - 1) * stride + columns * 4);
      apply(gl.getBufferSubData, self, [GL_PIXEL_PACK_BUFFER, start, copy]);
      noisePixels(copy, x, y, columns, rows, 0, stride, step);
      apply(gl.bufferSubData, self, [GL_PIXEL_PACK_BUFFER, start, copy]);
    } catch (_) {}
  };

  // Samples get the pixels' kind of noise (see noisePixels), on pairs of neighboring float32
  // values picked by index. Every sample up to the limit, which fingerprinting buffers stay far
  // under. Past it, a whole decoded track would stall the page for seconds on its first read, so
  // one sample in each run of `step` is decided, at a place keyed by the seed: a fixed one in a
  // few left the others exact at places the page could predict, the same on every site.
  const MAX_SAMPLES = 1000000;
  const sampleFloat = new Float32Array(1), sampleBits = new Uint32Array(sampleFloat.buffer);
  const noiseSamples = (samples, offset, total) => {
    if (read(typedKind, samples) !== 'Float32Array') return;
    const count = min(read(typedLength, samples), total - offset), step = max(1, ceil(total / MAX_SAMPLES));
    for (let run = floor(offset / step); run * step < offset + count; run++) {
      const index = run * step + (step > 1 ? (fmix(run ^ seedWords[1]) >>> 0) % step : 0), i = index - offset;
      if (i < 0 || i >= count) continue;
      const spot = fmix(imul(index ^ seedWords[2], 0x9e3779b1) ^ seedWords[0]), shift = spot >>> 31;
      sampleFloat[0] = samples[i];
      const pair = floor((sampleBits[0] + shift) / 2), low = 2 * pair - shift;
      // Pairs across a sign or exponent, or into infinities and NaN, are left alone.
      if (low < 0 || ((low ^ (low + 1)) & 0xff800000) !== 0 || (low & 0x7f800000) === 0x7f800000) continue;
      sampleBits[0] = low + (fmix(pair ^ spot ^ seedWords[3]) & 1);
      samples[i] = sampleFloat[0];
    }
  };

  const noiseBytes = (values) => {
    if (read(typedKind, values) !== 'Uint8Array') return;
    const length = read(typedLength, values);
    for (let i = 0; i < length; i++) {
      const spot = fmix(imul(i ^ seedWords[1], 0x9e3779b1) ^ seedWords[2]), shift = spot >>> 31;
      const pair = (values[i] + shift) >> 1, low = 2 * pair - shift;
      if (low < 0 || low > 254) continue;
      values[i] = low + (fmix(pair ^ spot ^ seedWords[3]) & 1);
    }
  };

  // Decibels: a tiny offset rounds away in float32, so each moves by up to 1e-5 of itself instead.
  const noiseFrequencies = (values, analyser) => {
    const length = min(values ? read(typedLength, values) : 0, read(frequencyBinCount, analyser));
    const next = prng(0x2545f491);
    for (let i = 0; i < length; i++) values[i] *= 1 + (next() - 0.5) * 2e-5;
  };

  const cores = (real) => max(2, min(real, 2 + floor(prng(0x51ed270b)() * (real - 1))));

  // Replacements report the original's source through toString, so pages cannot spot them. Shared
  // with the copies in parent, top and opener windows; only these functions, never the map, so no
  // native original can be reached through them.
  const replaced = new WeakMapCtor();
  let disguises = freeze({ __proto__: null,
    add: (replacement, original) => { apply(weakMapSet, replaced, [replacement, original]); },
    source: (fn) => {
      const original = apply(weakMapGet, replaced, [fn]);
      return original ? apply(sourceText, original, []) : undefined;
    } });

  // A protected window answers a cancelable event named MARK with its disguises, so WebKit's
  // injection and the hooks below never protect a frame twice. An event listener can't be listed or
  // forged. Privacy's Trusted Types script sends the same event with the realm's mode.
  let trustedTypesModes = new WeakMapCtor();
  // The windows that carry the adopter (see `protect`), shared likewise.
  let adopting = new WeakSetCtor();
  const answer = (event) => {
    apply(preventDefault, event, []);
    const box = read(eventDetail, event);
    if (box && !hasOwn(box, 'disguises')) defineProperty(box, 'disguises', { __proto__: null, value: disguises });
    if (box && !hasOwn(box, 'modes')) defineProperty(box, 'modes', { __proto__: null, value: trustedTypesModes });
    if (box && !hasOwn(box, 'adopting')) defineProperty(box, 'adopting', { __proto__: null, value: adopting });
    if (box && hasOwn(box, 'trustedTypes')) {
      const realm = sameOrigin(read(eventTarget, event));
      if (realm) apply(weakMapSet, trustedTypesModes, [realm, box.trustedTypes]);
    }
  };
  const ask = (win) => {
    const box = { __proto__: null };
    const event = new CustomEventCtor(MARK, { __proto__: null, cancelable: true, detail: box });
    return apply(dispatchEvent, win, [event]) ? null : box;
  };
  const sameOrigin = (win) => { try { return getPrototypeOf(win); } catch (_) { return null; } };
  try {
    const others = [parent, top, opener];
    for (let i = 0; i < others.length; i++) {
      const box = others[i] && others[i] !== window && sameOrigin(others[i]) ? ask(others[i]) : null;
      if (box && box.disguises) {
        disguises = box.disguises; trustedTypesModes = box.modes || trustedTypesModes; adopting = box.adopting || adopting;
        break;
      }
    }
  } catch (_) {}

  // The adopter must never reach a proxy's traps (`Object.keys` of a proxy asks about each key):
  // a proxy of such a window gets traps of this copy's, which forward every other key to the page's.
  const unlisted = (keys) => {
    const count = keys.length;
    for (let i = 0; i < count; i++) {
      if (keys[i] !== ADOPT) continue;
      for (let j = i + 1; j < count; j++) keys[j - 1] = keys[j];
      keys.length = count - 1;
      break;
    }
    return keys;
  };
  const shield = (target, handler) => {
    if (!apply(weakSetHas, adopting, [target]) || handler === null || (typeof handler !== 'object' && typeof handler !== 'function')) return handler;
    const traps = { __proto__: null };
    for (let i = 0; i < TRAPS.length; i++) {
      const name = TRAPS[i], forward = reflect[name];
      traps[name] = (...args) => {
        if (args[1] === ADOPT) return apply(forward, undefined, args);
        // Looked up on each call, as the browser does: the page may change its handler.
        const trap = handler[name];
        if (trap != null) return apply(trap, handler, args);
        const result = apply(forward, undefined, args);
        return name === 'ownKeys' ? unlisted(result) : result;
      };
    }
    return traps;
  };

  // A frame without a `src` fires `load` inside the insertion call, before the hooks below run.
  // A capture listener on the document, added before the page's, protects it first.
  // `document.open` drops it, so it is added again then.
  const frameLoaded = (event) => {
    const frame = read(eventTarget, event);
    const name = read(elementName, frame);
    if (name !== 'iframe' && name !== 'frame') return;
    try { protect(read(iframeWindow, frame) || read(frameWindow, frame)); } catch (_) {}
  };
  const watchLoads = (doc) => {
    try { apply(addEventListener, doc, ['load', frameLoaded, true]); } catch (_) {}
  };

  // Keyed by the realm's Window.prototype: a frame that navigates keeps its window but gets a new realm.
  const seen = new WeakSetCtor();
  // The window that opened each popup, by the popup's blank realm: its `opener` can be set to null.
  const creators = new WeakMapCtor();
  const opened = (child, creator) => {
    try {
      const realm = sameOrigin(child);
      if (realm) apply(weakMapSet, creators, [realm, creator]);
      protect(child);
    } catch (_) {}
  };
  const protect = (win) => {
    const realm = win ? sameOrigin(win) : null;
    if (!realm || apply(weakSetHas, seen, [realm])) return;
    apply(weakSetAdd, seen, [realm]);
    if (ask(win) !== null) return;
    apply(addEventListener, win, [MARK, answer]);
    watchLoads(win.document);
    // For the copy in this window's next page (see the top) and Privacy.trustedTypesScript.
    // Configurable: a proxy of the window whose keys left out a fixed one would throw.
    if (win !== window) {
      try {
        defineProperty(win, ADOPT, { __proto__: null, configurable: true, value: (doc, mode) => {
          const view = read(documentView, doc);
          if (!view || sameOrigin(view) !== realm) return;
          if (mode === 'enforce' || mode === 'report') { apply(weakMapSet, trustedTypesModes, [realm, mode]); return; }
          watchLoads(doc);
          try { watchParsing(doc); } catch (_) {}
        } });
        apply(weakSetAdd, adopting, [win]);
      } catch (_) {}
    }

    const nativeToString = win.Function.prototype.toString;
    const disguise = (replacement, original) => {
      defineProperty(replacement, 'name', { value: original.name });
      defineProperty(replacement, 'length', { value: original.length });
      disguises.add(replacement, original);
      return replacement;
    };
    const toString = disguise({ toString() {
      const source = disguises.source(this);
      return source === undefined ? apply(nativeToString, this, []) : source;
    } }.toString, nativeToString);
    defineProperty(win.Function.prototype, 'toString', { ...getOwnPropertyDescriptor(win.Function.prototype, 'toString'), value: toString });

    const patch = (proto, name, handler) => {
      const descriptor = proto && getOwnPropertyDescriptor(proto, name);
      if (!descriptor || typeof descriptor.value !== 'function') return null;
      const original = descriptor.value;
      const value = disguise({ [name](...args) { return handler(original, this, args); } }[name], original);
      defineProperty(proto, name, { ...descriptor, value });
      return original;
    };

    const patchGetter = (proto, name, handler) => {
      const descriptor = proto && getOwnPropertyDescriptor(proto, name);
      if (!descriptor || !descriptor.get) return;
      const original = descriptor.get;
      const get = disguise(getOwnPropertyDescriptor({ get [name]() { return handler(original, this); } }, name).get, original);
      defineProperty(proto, name, { ...descriptor, get });
    };

    const patchSetter = (proto, name, handler) => {
      const descriptor = proto && getOwnPropertyDescriptor(proto, name);
      if (!descriptor || !descriptor.set) return;
      const original = descriptor.set;
      const set = disguise(getOwnPropertyDescriptor({ set [name](value) { handler(original, this, value); } }, name).set, original);
      defineProperty(proto, name, { ...descriptor, set });
    };

    // Keeps the adopter out of every listing (see `shield`).
    try {
      const NativeProxy = win.Proxy;
      patch(NativeProxy, 'revocable', (target, self, args) => apply(target, self, [args[0], shield(args[0], args[1])]));
      // A proxy of the native one, which has no `prototype` a function would add.
      const ProxyShield = new NativeProxy(NativeProxy, { __proto__: null,
        construct: (target, args, newTarget) => construct(target, [args[0], shield(args[0], args[1])], newTarget) });
      disguises.add(ProxyShield, NativeProxy);
      defineProperty(win, 'Proxy', { ...getOwnPropertyDescriptor(win, 'Proxy'), value: ProxyShield });
      patch(win.Object, 'getOwnPropertyNames', (target, self, args) => unlisted(apply(target, self, args)));
      patch(win.Reflect, 'ownKeys', (target, self, args) => unlisted(apply(target, self, args)));
      patch(win.Object, 'getOwnPropertyDescriptors', (target, self, args) => {
        const all = apply(target, self, args);
        delete all[ADOPT];
        return all;
      });
    } catch (_) {}

    try {
      const getImageData = patch(win.CanvasRenderingContext2D.prototype, 'getImageData', readImage);
      const farbledCopy = (canvas) => {
        // Anything but a canvas reads as empty and goes on to the native call, which throws as usual.
        const width = read(canvasWidth.get, canvas), height = read(canvasHeight.get, canvas);
        if (!width || !height) return canvas;
        const copy = apply(createElement, win.document, ['canvas']);
        apply(canvasWidth.set, copy, [width]);
        apply(canvasHeight.set, copy, [height]);
        const context = apply(getContext, copy, ['2d']);
        apply(drawImage, context, [canvas, 0, 0]);
        const image = apply(getImageData, context, [0, 0, width, height]);
        noisePixels(apply(imageData, image, []), 0, 0, width, height, 0, width * 4, ceil(width * height / MAX_PIXELS));
        apply(putImageData, context, [image, 0, 0]);
        return copy;
      };
      patch(win.HTMLCanvasElement.prototype, 'toDataURL', (target, self, args) => apply(target, farbledCopy(self), args));
      patch(win.HTMLCanvasElement.prototype, 'toBlob', (target, self, args) => apply(target, farbledCopy(self), args));
    } catch (_) {}

    try {
      const offscreenGetImageData = patch(win.OffscreenCanvasRenderingContext2D.prototype, 'getImageData', readImage);
      patch(win.OffscreenCanvas.prototype, 'convertToBlob', (target, self, args) => {
        const width = read(offscreenWidth, self), height = read(offscreenHeight, self);
        if (!width || !height) return apply(target, self, args);
        const copy = new OffscreenCanvasCtor(width, height);
        const context = apply(offscreenGetContext, copy, ['2d']);
        apply(offscreenDrawImage, context, [self, 0, 0]);
        const image = apply(offscreenGetImageData, context, [0, 0, width, height]);
        noisePixels(apply(imageData, image, []), 0, 0, width, height, 0, width * 4, ceil(width * height / MAX_PIXELS));
        apply(offscreenPutImageData, context, [image, 0, 0]);
        return apply(target, copy, args);
      });
    } catch (_) {}

    try {
      // Indexed loops here and below: the page may have replaced the array iterator by now.
      const contexts = [win.WebGLRenderingContext, win.WebGL2RenderingContext];
      const members = [gl1, gl2];
      for (let i = 0; i < contexts.length; i++) {
        const gl = members[i], webgl2 = i === 1;
        patch(contexts[i] && contexts[i].prototype, 'readPixels', (target, self, args) => {
          readPixelsArguments(args, webgl2);
          const result = apply(target, self, args);
          readPixelsNoise(gl, webgl2, self, args);
          return result;
        });
      }
    } catch (_) {}

    try {
      const farbled = new WeakSetCtor();
      patch(win.AudioBuffer.prototype, 'getChannelData', (target, self, args) => {
        const samples = apply(target, self, args);
        if (!apply(weakSetHas, farbled, [samples])) {
          apply(weakSetAdd, farbled, [samples]);
          noiseSamples(samples, 0, read(typedLength, samples));
        }
        return samples;
      });
      // The offset is converted once, as the native call would (see readImage).
      patch(win.AudioBuffer.prototype, 'copyFromChannel', (target, self, args) => {
        if (args.length > 2) args[2] = args[2] >>> 0;
        const result = apply(target, self, args);
        noiseSamples(args[0], args.length > 2 ? args[2] : 0, read(audioBufferLength, self));
        return result;
      });
      patch(win.AnalyserNode.prototype, 'getFloatFrequencyData', (target, self, args) => {
        const result = apply(target, self, args);
        noiseFrequencies(args[0], self);
        return result;
      });
      patch(win.AnalyserNode.prototype, 'getFloatTimeDomainData', (target, self, args) => {
        const result = apply(target, self, args);
        noiseSamples(args[0], 0, read(typedLength, args[0]));
        return result;
      });
      const bytes = ['getByteFrequencyData', 'getByteTimeDomainData'];
      for (let i = 0; i < bytes.length; i++) {
        patch(win.AnalyserNode.prototype, bytes[i], (target, self, args) => {
          const result = apply(target, self, args);
          noiseBytes(args[0]);
          return result;
        });
      }
    } catch (_) {}

    try {
      patchGetter(win.Navigator.prototype, 'hardwareConcurrency', (target, self) => cores(apply(target, self, [])));
    } catch (_) {}

    // Installed voices differ from Mac to Mac; expose only the default voice and those
    // of the page's language, which every Mac with that language ships.
    try {
      patch(win.SpeechSynthesis.prototype, 'getVoices', (target, self, args) => {
        const tag = apply(toLowerCase, read(navigatorLanguage, ourNavigator) || 'en', []);
        const dash = apply(indexOf, tag, ['-']);
        const language = dash < 0 ? tag : apply(slice, tag, [0, dash]);
        // Compacted in place, so the result stays the frame's own array.
        const voices = apply(target, self, args);
        let kept = 0;
        for (let i = 0; i < voices.length; i++) {
          const voice = voices[i];
          if (apply(voiceDefault, voice, []) ||
              (apply(voiceLocal, voice, []) && apply(startsWith, apply(toLowerCase, apply(voiceLang, voice, []), []), [language]))) {
            voices[kept++] = voice;
          }
        }
        voices.length = kept;
        return voices;
      });
    } catch (_) {}

    // Same-origin frames get the same treatment the moment the page can reach them.
    const protectFrame = (frame) => {
      try { protect(read(iframeWindow, frame) || read(frameWindow, frame)); } catch (_) {}
    };
    const framesIn = (node) => {
      try { return apply(queryAll[apply(nodeType, node, [])], node, ['iframe, frame']); } catch (_) { return null; }
    };
    const protectAll = (found) => {
      const count = found === null ? 0 : read(nodeCount, found);
      for (let i = 0; i < count; i++) protectFrame(found[i]);
    };
    // Runs on every DOM insertion of the page, so it does as little as it can.
    const protectInserted = (node) => {
      if (node === null || typeof node !== 'object' || read(nodeType, node) !== 1) return;
      const name = read(elementName, node);
      if (name === 'iframe' || name === 'frame') protectFrame(node);
      else if (read(firstElementChild, node) && apply(querySelector, node, ['iframe, frame']) !== null) protectAll(framesIn(node));
    };
    // A fragment hands its children over on insertion, so its frames are listed before.
    const framesBefore = (node) => node !== null && typeof node === 'object' && read(nodeType, node) === 11 ? framesIn(node) : null;
    const protectAfter = (fragmentFrames, node) => {
      if (fragmentFrames === null) protectInserted(node); else protectAll(fragmentFrames);
    };
    // Insertion methods are among the hottest DOM calls: forward `arguments`, no array or handler.
    const hookInsertion = (proto, name, variadic) => {
      const descriptor = proto && getOwnPropertyDescriptor(proto, name);
      if (!descriptor || typeof descriptor.value !== 'function') return;
      const original = descriptor.value;
      const replacement = variadic
        ? { [name]() {
            // Fragments are rare here: their frames go in an object of their own, not an array a page could set up.
            let fragments = null, count = 0;
            for (let i = 0; i < arguments.length; i++) {
              const found = framesBefore(arguments[i]);
              if (found !== null) { if (fragments === null) fragments = { __proto__: null }; fragments[count++] = found; }
            }
            const result = apply(original, this, arguments);
            for (let i = 0; i < arguments.length; i++) protectInserted(arguments[i]);
            for (let i = 0; i < count; i++) protectAll(fragments[i]);
            return result;
          } }[name]
        : { [name](node) {
            const fragmentFrames = framesBefore(node);
            const result = apply(original, this, arguments);
            protectAfter(fragmentFrames, node);
            return result;
          } }[name];
      defineProperty(proto, name, { ...descriptor, value: disguise(replacement, original) });
    };
    // Markup reaches no insertion method: its frames are looked up once it is in.
    const mayHoldFrame = (markup) => typeof markup !== 'string' || apply(regExpExec, FRAME_TAG, [markup]) !== null;
    const hookMarkup = (proto, name, at) => patch(proto, name, (target, self, args) => {
      // Markup put next to the element lands in its parent.
      const container = read(parentNode, self) || self;
      const result = apply(target, self, args);
      if (mayHoldFrame(args[at])) protectAll(framesIn(container));
      return result;
    });
    try {
      const frameTypes = [win.HTMLIFrameElement.prototype, win.HTMLFrameElement.prototype];
      for (let i = 0; i < frameTypes.length; i++) {
        const proto = frameTypes[i];
        patchGetter(proto, 'contentWindow', (target, self) => {
          const child = apply(target, self, []);
          try { protect(child); } catch (_) {}
          return child;
        });
        patchGetter(proto, 'contentDocument', (target, self) => {
          protectFrame(self);
          return apply(target, self, []);
        });
      }
      const single = ['appendChild', 'insertBefore', 'replaceChild'];
      for (let i = 0; i < single.length; i++) hookInsertion(win.Node.prototype, single[i], false);
      const variadic = ['append', 'prepend', 'after', 'before', 'replaceWith', 'replaceChildren'];
      for (let i = 0; i < variadic.length; i++) hookInsertion(win.Element.prototype, variadic[i], true);
      const siblings = ['after', 'before', 'replaceWith'];
      for (let i = 0; i < siblings.length; i++) hookInsertion(win.CharacterData.prototype, siblings[i], true);
      patch(win.Element.prototype, 'insertAdjacentElement', (target, self, args) => {
        const result = apply(target, self, args);
        protectInserted(args[1]);
        return result;
      });
      patch(win.Range.prototype, 'insertNode', (target, self, args) => {
        const fragmentFrames = framesBefore(args[0]);
        const result = apply(target, self, args);
        protectAfter(fragmentFrames, args[0]);
        return result;
      });

      // `frames[n]` reaches a frame without the getters above, so markup is covered where it lands.
      const markupSetter = (proto, name, outer) => patchSetter(proto, name, (target, self, value) => {
        const container = outer ? read(parentNode, self) : self;
        apply(target, self, [value]);
        if (mayHoldFrame(value)) protectAll(framesIn(container));
      });
      markupSetter(win.Element.prototype, 'innerHTML', false);
      markupSetter(win.ShadowRoot.prototype, 'innerHTML', false);
      markupSetter(win.Element.prototype, 'outerHTML', true);
      hookMarkup(win.Element.prototype, 'insertAdjacentHTML', 1);
      hookMarkup(win.Element.prototype, 'setHTMLUnsafe', 0);
      hookMarkup(win.ShadowRoot.prototype, 'setHTMLUnsafe', 0);
      const documentProto = hasOwn(win.Document.prototype, 'write') ? win.Document.prototype : win.HTMLDocument.prototype;
      // Opening a document (writing to a loaded one does) drops its window's listeners, the marker's
      // too. That window may be a frame's, not `win`.
      const remark = (doc) => {
        try {
          const view = read(documentView, doc);
          const realm = view ? sameOrigin(view) : null;
          if (realm && apply(weakSetHas, seen, [realm])) {
            apply(addEventListener, view, [MARK, answer]);
            watchLoads(doc);
          }
        } catch (_) {}
      };
      patch(documentProto, 'open', (target, self, args) => {
        const result = apply(target, self, args);
        // With three arguments it opens a window instead, as `open` does: a blank popup to protect.
        if (args.length > 2) opened(result, read(documentView, self)); else remark(self);
        return result;
      });
      // From its response's headers (see Privacy.trustedTypes) or a policy in its markup. A blank or
      // `srcdoc` frame or a popup has its creator's policies.
      const trustedTypesMode = (doc) => {
        for (let depth = 0; doc && depth < 32; depth++) {
          const view = read(documentView, doc);
          const realm = view ? sameOrigin(view) : null;
          let mode = (realm && apply(weakMapGet, trustedTypesModes, [realm])) || apply(weakMapGet, trustedTypesModes, [doc]);
          try {
            if (mode !== 'enforce' && hasTrustedTypesMeta(doc)) {
              mode = 'enforce';
              apply(weakMapSet, trustedTypesModes, [doc, mode]);
            }
          } catch (_) {}
          if (mode || !realm || !apply(regExpExec, NO_RESPONSE, [`${read(documentURL, doc)}`])) return mode;
          let creator = null;
          try { creator = view.parent !== view ? view.parent : apply(weakMapGet, creators, [realm]) || view.opener; } catch (_) {}
          try { doc = creator && sameOrigin(creator) ? creator.document : null; } catch (_) { doc = null; }
        }
        return undefined;
      };
      const nativeWrite = member(documentProto, 'write').value;
      const writes = ['write', 'writeln'];
      for (let i = 0; i < writes.length; i++) {
        const sink = 'Document ' + writes[i];
        patch(documentProto, writes[i], (target, self, args) => {
          // Each argument is converted once, as the native call does (a page can count `toString` calls).
          let written = { __proto__: null, length: args.length }, joined = '', plain = false;
          for (let j = 0; j < args.length; j++) {
            const arg = args[j];
            if (isTrustedHTML && apply(isTrustedHTML, trustedTypesFactory, [arg])) {
              written[j] = arg;
              joined += apply(trustedHTMLText, arg, []);
            } else {
              written[j] = `${arg}`;
              joined += written[j];
              plain = true;
            }
          }
          // A write that opens the document drops the `load` listener before the markup's frames
          // fire it. So an empty write opens it first, when the browser would, and the listener
          // is put back. Where Trusted Types apply, plain markup is checked first: a rejected
          // write must throw with the document unopened.
          let open = mayHoldFrame(joined);
          if (open && plain && isTrustedHTML && !(read(readyState, self) === 'loading' && read(currentScript, self))) {
            const view = read(documentView, self);
            const mode = trustedTypesMode(self);
            const policy = mode && view ? read(defaultPolicy, read(windowTrustedTypes, view)) : null;
            if (policy) {
              // Called as the browser would, with this sink. An empty answer may be a refusal,
              // which only the browser's own call reports, so the plain markup goes on.
              const html = apply(createHTML, policy, [joined, 'TrustedHTML', sink]);
              if (apply(trustedHTMLText, html, []) !== '') written = [html]; else open = mode !== 'enforce';
            } else {
              // Without one, an enforced policy rejects the write; one that only reports lets it through.
              open = mode !== 'enforce';
            }
          }
          if (open) { try { apply(nativeWrite, self, []); } catch (_) {} }
          remark(self);
          const result = apply(target, self, written);
          remark(self);
          for (let j = 0; j < written.length; j++) {
            if (mayHoldFrame(written[j])) { protectAll(framesIn(self)); break; }
          }
          return result;
        });
      }
    } catch (_) {}

    // WebKit injects nothing into a popup until its first page loads, but the opener reaches it at once.
    try {
      patch(hasOwn(win, 'open') ? win : win.Window.prototype, 'open', (target, self, args) => {
        // A bare `open()` calls it without a `this`, which the native one takes for the window.
        const opener = self == null ? win : self;
        const child = apply(target, opener, args);
        opened(child, opener);
        return child;
      });
    } catch (_) {}
  };

  // The parser adds frames through no method the hooks see, and `frames[n]` reaches them past the
  // getters. While the page parses, an observer protects them before each inline script runs.
  let watchParsing = () => {};
  try {
    const MutationObserverCtor = MutationObserver;
    const observe = MutationObserver.prototype.observe;
    const disconnect = MutationObserver.prototype.disconnect;
    const takeRecords = MutationObserver.prototype.takeRecords;
    const addedNodes = member(MutationRecord.prototype, 'addedNodes').get;
    const protectFrame = (frame) => {
      try { protect(read(iframeWindow, frame) || read(frameWindow, frame)); } catch (_) {}
    };
    // Only elements whose parent isn't in the batch are searched, or nested nodes are searched
    // once per level.
    watchParsing = (doc) => {
      const parsed = (records) => {
        const batch = new WeakSetCtor();
        for (let pass = 0; pass < 2; pass++) for (let i = 0; i < records.length; i++) {
          const added = read(addedNodes, records[i]);
          const count = added ? read(nodeCount, added) : 0;
          for (let j = 0; j < count; j++) {
            const node = added[j];
            if (read(nodeType, node) !== 1) continue;
            if (pass === 0) { apply(weakSetAdd, batch, [node]); continue; }
            const name = read(elementName, node);
            if (name === 'iframe' || name === 'frame') protectFrame(node);
            else if (read(firstElementChild, node) && !apply(weakSetHas, batch, [read(parentNode, node)])) {
              const found = apply(queryAll[1], node, ['iframe, frame']);
              const total = read(nodeCount, found);
              for (let k = 0; k < total; k++) protectFrame(found[k]);
            }
          }
        }
        // A Trusted Types policy in the markup still applies once a script removes it.
        if (isTrustedHTML && records.length && !apply(weakMapGet, trustedTypesModes, [doc])) {
          try {
            if (hasTrustedTypesMeta(doc)) apply(weakMapSet, trustedTypesModes, [doc, 'enforce']);
          } catch (_) {}
        }
        // `document.open` while the page loads drops the `DOMContentLoaded` listener below, so the
        // first batch after parsing ends stops the observer too.
        if (read(readyState, doc) !== 'loading') apply(disconnect, observer, []);
      };
      const observer = new MutationObserverCtor(parsed);
      apply(observe, observer, [doc, { __proto__: null, childList: true, subtree: true }]);
      apply(addEventListener, doc, ['DOMContentLoaded', () => {
        parsed(apply(takeRecords, observer, []));
        apply(disconnect, observer, []);
      }, { __proto__: null, once: true }]);
    };
  } catch (_) {}

  protect(window);
  watchLoads(document);
  try { watchParsing(document); } catch (_) {}
})();
