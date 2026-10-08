// Brave-style farbling: tiny, deterministic noise per (session, site) so fingerprints
// stay stable on one site but cannot be linked across sites or sessions.
// WebKit's own fingerprinting protections run underneath (see Privacy.swift); this covers
// what they leave in the page's windows: audio, WebGL and offscreen reads, CPU count, voices,
// and same-origin iframes, a classic way to fetch pristine APIs from a fresh window.
// Not workers: WebKit injects user scripts into documents only, and the one way in, running a
// worker from a blob that imports the page's script, gives the worker a blob address. Relative
// URLs in it (importScripts, fetch, nested workers) then fail; a CSP that allows the worker's
// address but not blob: refuses it, and one whose script-src doesn't cover that address refuses
// the import inside the worker, where nothing can fall back; a SharedWorker would no longer be
// shared. So a worker sees the real CPU count and unfarbled OffscreenCanvas and WebGL reads.
(() => {
  'use strict';
  // Keyed hashes of the top page's site under a key of the launch (see Privacy.farbling): every
  // frame of a page gets them (frames of another origin mix theirs in, below), and nothing leads
  // from them to the key or another site's.
  const SEED = '__LITHIUM_SEED__';
  // Names the marker below: one per launch key, not per site, so the copies of a popup and of
  // the cross-site frame that opened it still find each other. A page never sees it.
  const MARK = '__LITHIUM_MARK__';
  const MAX_PIXELS = 500000;
  const MAX_SAMPLES = 500000;
  // Taken once: the page shares this world and could replace any of them before a frame or
  // popup it opens is protected (a `call` that always returns true once skipped them), or skew
  // the noise itself (a `Math.floor` that returned a huge gap once left every pixel clean).
  const apply = Reflect.apply;
  const { hasOwn, defineProperty, getOwnPropertyDescriptor } = Object;
  const { imul, floor, ceil, max, min, trunc } = Math;
  const BigIntCtor = BigInt, { asIntN } = BigInt, NumberCtor = Number, { isFinite } = Number;
  const WeakMapCtor = WeakMap, WeakSetCtor = WeakSet;
  const weakMapGet = WeakMap.prototype.get;
  const weakMapSet = WeakMap.prototype.set;
  const weakSetHas = WeakSet.prototype.has;
  const weakSetAdd = WeakSet.prototype.add;
  // The canvas and array members the noise goes through, likewise: a canvas `width` that reads
  // 0, an empty `putImageData` or an array `length` past the limit once left every read clean.
  // They work on objects of any same-origin realm, so these serve the frames and popups too.
  const member = (proto, name) => (proto && getOwnPropertyDescriptor(proto, name)) || {};
  const read = (getter, self) => { try { return apply(getter, self, []); } catch (_) { return 0; } };
  const Uint8ArrayCtor = Uint8Array;
  const typedArray = Object.getPrototypeOf(Uint8Array.prototype);
  const typedLength = member(typedArray, 'length').get;
  const typedKind = member(typedArray, Symbol.toStringTag).get;
  const imageWidth = member(ImageData.prototype, 'width').get;
  const imageHeight = member(ImageData.prototype, 'height').get;
  const imageData = member(ImageData.prototype, 'data').get;
  const audioBufferLength = member(globalThis.AudioBuffer && AudioBuffer.prototype, 'length').get;
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
  // And the members the voice filter reads: an `Array` `filter` that keeps everything or a voice
  // `default` that is always true once handed back every installed voice.
  const ourNavigator = navigator;
  const navigatorLanguage = member(Navigator.prototype, 'language').get;
  const voiceProto = globalThis.SpeechSynthesisVoice && SpeechSynthesisVoice.prototype;
  const voiceDefault = member(voiceProto, 'default').get;
  const voiceLocal = member(voiceProto, 'localService').get;
  const voiceLang = member(voiceProto, 'lang').get;
  const { toLowerCase, startsWith, indexOf, slice } = String.prototype;
  // And what marks a protected window, and finds the frames that markup creates.
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
  // Looked for in the head only, the one place WebKit takes such a policy from: it stays small.
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
  // A frame of another origin than the top page's mixes that origin in: a tracker framed on a site
  // farbles apart from the site's own pages, not only from one site to the next. Blank and srcdoc
  // frames have their creator's origin, and its noise: hence the document's `origin`, as
  // `location.origin` is their address's, "null". Read from `ancestorOrigins`, as touching a
  // cross-origin `top` would log an error in every such frame.
  try {
    const ancestors = location.ancestorOrigins, origin = globalThis.origin;
    if (ancestors && ancestors.length && ancestors[ancestors.length - 1] !== origin) {
      let frame = 0x811c9dc5;
      for (let i = 0; i < origin.length; i++) frame = imul(frame ^ origin.charCodeAt(i), 0x01000193);
      for (let i = 0; i < 4; i++) seedWords[i] = fmix(seedWords[i] ^ frame ^ i);
    }
  } catch (_) {}

  // sfc32 over the seed's 128 bits with `salt` mixed in: too much state to search from a few
  // noisy samples, unlike the 32 bits it once had. The first outputs are dropped to spread the salt.
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

  // RGBA bytes of `width` × `height` pixels from `start` in `data`, the first at (`left`, `top`) in
  // the canvas. Each pixel is decided on its own, from its spot in the canvas and its color, never
  // from where the read starts: a 1×1 read gets the noise a full one has there, so reading small
  // windows and comparing them shows nothing.
  // One color of the pixel (picked by spot) moves within a pair of values, 2k - o and 2k + 1 - o
  // with `o` picked by spot too, and the pixel is decided on its other colors and that pair, not
  // the exact value: one pixel in ten is set to a value of its pair, which moves it half the time.
  // Both values of a noisy pair come back as the same one, so the page can't tell which it drew;
  // and noising a noised pixel changes nothing, so pixels the page puts back and reads again (an
  // editor's canvas, a data URL drawn back) keep the values they were given, and never drift
  // further than one. Clearing low bits doesn't undo it: for half the spots the pair straddles them.
  // Rows are `stride` bytes apart (WebGL can pad them). With a `step`, for reads past the limit,
  // only one pixel in `step` along a row is decided, picked by its spot and so staggered by row.
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
        // The pixel with that color replaced by its pair.
        const color = (data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24) ^ ((value ^ pair) << (channel << 3));
        const decision = fmix(color ^ spot ^ seedWords[2]);
        if ((decision & 0xffff) < 6554) data[at + channel] = low + ((decision >>> 16) & 1);
      }
    }
  };

  // `getImageData` and its noise. The read's spot is converted here, once, as the native call
  // would: a value converting differently each time could otherwise move the noise.
  const readImage = (target, self, args) => {
    if (args.length >= 4) for (let i = 0; i < 4; i++) args[i] = +args[i];
    const image = apply(target, self, args);
    const width = apply(imageWidth, image, []), height = apply(imageHeight, image, []);
    if (width * height <= MAX_PIXELS) {
      // A negative width or height reads that far back from the spot given.
      noisePixels(apply(imageData, image, []), (args[0] | 0) + min(args[2] | 0, 0), (args[1] | 0) + min(args[3] | 0, 0), width, height, 0);
    }
    return image;
  };

  // WebGL `readPixels` gets the same noise, on what it wrote only: RGBA bytes from `start` (WebGL2's
  // offset into the array), laid out as the pack alignment, row length and skips say. Integer
  // formats (RGBA_INTEGER) and floats are left exact, and so are reads of up to 16 pixels: those
  // are most likely GPU picking, which reads an object's id back from its color, where a step of
  // one picks another object. A page could read a scene that way pixel by pixel, unnoised: the
  // price of not breaking picking. The canvas's `toDataURL` and `toBlob` are still noised.
  // A read that writes nothing (a lost context, into an array while a pack buffer is bound, an
  // incomplete framebuffer) gets no noise either: the array holds the page's own data then, as it
  // does for the pixels of a read past the edges, which WebGL leaves alone. The canvas's edges are
  // known; a bound framebuffer's are not (WebGL can't tell a texture's size), so only the bottom
  // left ones count there. Rarer errors (a float framebuffer read as bytes) are page bugs, and not
  // checked for. WebGL2 can read into a bound pack buffer instead, at an offset: see below.
  const GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401;
  const GL_PACK_ROW_LENGTH = 0x0D02, GL_PACK_SKIP_ROWS = 0x0D03, GL_PACK_SKIP_PIXELS = 0x0D04, GL_PACK_ALIGNMENT = 0x0D05;
  const GL_PIXEL_PACK_BUFFER_BINDING = 0x88ED, GL_FRAMEBUFFER = 0x8D40, GL_READ_FRAMEBUFFER = 0x8CA8, GL_FRAMEBUFFER_COMPLETE = 0x8CD5;
  const GL_FRAMEBUFFER_BINDING = 0x8CA6, GL_READ_FRAMEBUFFER_BINDING = 0x8CAA, GL_PIXEL_PACK_BUFFER = 0x88EB, GL_BUFFER_SIZE = 0x8764;
  // The arguments are converted here, once, as the native call would (see `readImage`): a format
  // given as '6408' read the same to it, and skipped the noise. The offsets too, a GLuint and a
  // GLintptr: NaN or Infinity read at 0 natively, and once skipped the noise here.
  const readPixelsArguments = (args, webgl2) => {
    if (args.length < 7) return;
    for (let i = 0; i < 6; i++) args[i] = i < 4 ? args[i] | 0 : args[i] >>> 0;
    if (args[6] && typeof args[6] === 'object') { if (args.length > 7) args[7] = args[7] >>> 0; }
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
      // A row length that doesn't hold the row and its skipped pixels is an error.
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
    // Past the limit, a share of the pixels, so the cost stays the same. Counted on what the read
    // covers of the canvas, not the size asked for: a huge read of a small canvas noises it all.
    const x = args[0] + left, y = args[1] + bottom, columns = right - left, rows = top - bottom;
    const step = ceil(columns * rows / MAX_PIXELS);
    start += bottom * stride + left * 4;
    if (!packed) { noisePixels(pixels, x, y, columns, rows, start, stride, step); return; }
    // Pixels read into a pack buffer are read back and written over with the same noise: noising
    // `getBufferSubData` instead would miss the page reading the buffer through another binding.
    try {
      const copy = new Uint8ArrayCtor((rows - 1) * stride + columns * 4);
      apply(gl.getBufferSubData, self, [GL_PIXEL_PACK_BUFFER, start, copy]);
      noisePixels(copy, x, y, columns, rows, 0, stride, step);
      apply(gl.bufferSubData, self, [GL_PIXEL_PACK_BUFFER, start, copy]);
    } catch (_) {}
  };

  // Samples get the pixels' kind of noise (see noisePixels): each moves within a pair of
  // neighboring float32 values picked by its index in the buffer, and is decided on that pair. Noise
  // read off a silent buffer is that of silence only, so it can't be taken off another; noising
  // twice changes nothing (`getChannelData` noises the buffer itself, which `copyFromChannel` then
  // reads); and a window copied from the middle gets what the whole buffer has there. `samples`
  // holds the buffer's samples from `offset` on, of `total`. Every sample, however long the
  // buffer: noising one in a few left the others exact, at places the page could predict. The cost
  // follows what the page has rendered or copied, and `getChannelData` noises a buffer once.
  const sampleFloat = new Float32Array(1), sampleBits = new Uint32Array(sampleFloat.buffer);
  const noiseSamples = (samples, offset, total) => {
    if (read(typedKind, samples) !== 'Float32Array') return;
    const count = min(read(typedLength, samples), total - offset);
    for (let i = 0; i < count; i++) {
      const spot = fmix(imul((offset + i) ^ seedWords[2], 0x9e3779b1) ^ seedWords[0]), shift = spot >>> 31;
      sampleFloat[0] = samples[i];
      const pair = floor((sampleBits[0] + shift) / 2), low = 2 * pair - shift;
      // Pairs across a sign or exponent, or into infinities and NaN, are left alone.
      if (low < 0 || ((low ^ (low + 1)) & 0xff800000) !== 0 || (low & 0x7f800000) === 0x7f800000) continue;
      sampleBits[0] = low + (fmix(pair ^ spot ^ seedWords[3]) & 1);
      samples[i] = sampleFloat[0];
    }
  };

  // An analyser's bytes the same way, each in a pair of neighboring values picked by its index.
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

  // Frequencies are decibels, around -30 to -100: an offset as small as the samples' rounds away
  // in float32, so each moves by up to 1e-5 of itself instead (a ten-thousandth of a decibel).
  const noiseFrequencies = (values) => {
    const length = values ? apply(typedLength, values, []) : 0;
    if (length > MAX_SAMPLES) return;
    const next = prng(0x2545f491);
    for (let i = 0; i < length; i++) values[i] *= 1 + (next() - 0.5) * 2e-5;
  };

  const cores = (real) => max(2, min(real, 2 + floor(prng(0x51ed270b)() * (real - 1))));

  // Replacements report the original's source through toString, so pages cannot spot them. One
  // map for every realm this copy protects, joined with the map of the copy in the parent, top or
  // opener window: any realm's toString then sees through the replacements of all the others.
  let disguises = new WeakMapCtor();

  // A protected window answers a cancelable event named MARK: the copy that protects it cancels it
  // and hands over its disguises. WebKit's per-frame injection and the hooks below can both reach a
  // frame (a blank one keeps its realm when its page loads), so each copy asks before protecting.
  // An event listener can't be listed or forged, unlike the window property this once was.
  // The same event, sent by the script Privacy adds for a response that asks for Trusted Types,
  // tells the window's realm whether its policy enforces them or only reports. Shared like the
  // disguises, so a frame's copy finds its parent's.
  let trustedTypesModes = new WeakMapCtor();
  const answer = (event) => {
    apply(preventDefault, event, []);
    const box = read(eventDetail, event);
    if (box && !hasOwn(box, 'disguises')) defineProperty(box, 'disguises', { __proto__: null, value: disguises });
    if (box && !hasOwn(box, 'modes')) defineProperty(box, 'modes', { __proto__: null, value: trustedTypesModes });
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
  // Cross-origin windows have no prototype to give, and are left alone.
  const sameOrigin = (win) => { try { return getPrototypeOf(win); } catch (_) { return null; } };
  try {
    const others = [parent, top, opener];
    for (let i = 0; i < others.length; i++) {
      const box = others[i] && others[i] !== window && sameOrigin(others[i]) ? ask(others[i]) : null;
      if (box && box.disguises) { disguises = box.disguises; trustedTypesModes = box.modes || trustedTypesModes; break; }
    }
  } catch (_) {}

  // A frame without a `src` fires `load` while it is being inserted: inside the native call, before
  // the hooks below or the observer at the end run, and a handler there reaches it through
  // `frames`. A capture listener on the document, added before any of the page's, protects it
  // first (`load` never reaches the window). `document.open` drops it, so it is added again then.
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

    const nativeToString = win.Function.prototype.toString;
    const disguise = (replacement, original) => {
      defineProperty(replacement, 'name', { value: original.name });
      defineProperty(replacement, 'length', { value: original.length });
      apply(weakMapSet, disguises, [replacement, original]);
      return replacement;
    };
    const toString = disguise({ toString() { return apply(nativeToString, apply(weakMapGet, disguises, [this]) || this, []); } }.toString, nativeToString);
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

    try {
      const getImageData = patch(win.CanvasRenderingContext2D.prototype, 'getImageData', readImage);
      const farbledCopy = (canvas) => {
        // Anything but a canvas reads as empty and goes on to the native call, which throws as usual.
        const width = read(canvasWidth.get, canvas), height = read(canvasHeight.get, canvas);
        if (!width || !height || width * height > MAX_PIXELS) return canvas;
        const copy = apply(createElement, win.document, ['canvas']);
        apply(canvasWidth.set, copy, [width]);
        apply(canvasHeight.set, copy, [height]);
        const context = apply(getContext, copy, ['2d']);
        apply(drawImage, context, [canvas, 0, 0]);
        const image = apply(getImageData, context, [0, 0, width, height]);
        noisePixels(apply(imageData, image, []), 0, 0, width, height, 0);
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
        if (!width || !height || width * height > MAX_PIXELS) return apply(target, self, args);
        const copy = new OffscreenCanvasCtor(width, height);
        const context = apply(offscreenGetContext, copy, ['2d']);
        apply(offscreenDrawImage, context, [self, 0, 0]);
        const image = apply(offscreenGetImageData, context, [0, 0, width, height]);
        noisePixels(apply(imageData, image, []), 0, 0, width, height, 0);
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
      // The offset is converted once, as the native call would (see readImage): the copy's noise
      // is keyed on where it starts in the buffer, and covers only what it copied.
      patch(win.AudioBuffer.prototype, 'copyFromChannel', (target, self, args) => {
        if (args.length > 2) args[2] = args[2] >>> 0;
        const result = apply(target, self, args);
        noiseSamples(args[0], args.length > 2 ? args[2] : 0, read(audioBufferLength, self));
        return result;
      });
      patch(win.AnalyserNode.prototype, 'getFloatFrequencyData', (target, self, args) => {
        const result = apply(target, self, args);
        noiseFrequencies(args[0]);
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
        // The language is the same in every frame and popup, so this window's navigator serves them all.
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
    // Runs on every DOM insertion of the page, so it does as little as it can: most nodes
    // are elements without children, which cannot hold a frame. Through the saved members, as
    // everywhere: a frame given an own `nodeType` of 3 once went in unprotected.
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
    // Insertion methods are among the hottest DOM calls: their replacements forward
    // `arguments` instead of collecting them in an array and calling through a handler.
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
    // Markup reaches no insertion method: once it is in, the frames it may have made are looked
    // up, when it names one (or isn't a plain string, such as TrustedHTML).
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
      // Opening a document, which writing to a loaded one does, drops its window's listeners: the
      // marker's too. That is the document's own window, which may be a frame's, not `win`.
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
      // Whether Trusted Types apply to a document: from its response's headers (see
      // Privacy.trustedTypes), or a policy in its markup, which still applies once removed and so
      // is kept. A blank or `srcdoc` frame or a popup has no response and its creator's policies.
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
          // Each argument is converted once, as the native call does (a page can count its
          // `toString` calls), and TrustedHTML is passed on as is.
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
          // A write the parser has no place for opens the document inside the native call, which
          // drops the `load` listener before the markup's frames fire it. For markup that may hold
          // one, an empty write opens it first, exactly when the browser would (not while the
          // document's external or module script runs, say): the real write then finds the parser
          // open and the listener back. No arguments, so no Trusted Types check: the real write
          // runs that before anything else, and one it rejects must throw with the document
          // unopened. So plain markup is checked first where Trusted Types apply, unless a script
          // of the parsing document is running: its write goes where the parser is, or is
          // ignored, and never opens the document.
          let open = mayHoldFrame(joined);
          if (open && plain && isTrustedHTML && !(read(readyState, self) === 'loading' && read(currentScript, self))) {
            const view = read(documentView, self);
            const mode = trustedTypesMode(self);
            const policy = mode && view ? read(defaultPolicy, read(windowTrustedTypes, view)) : null;
            if (policy) {
              // Called as the browser would call it, with this sink: its answer then goes in
              // as TrustedHTML, which the browser doesn't run it on again. An empty one may be a
              // refusal, which only the browser's own call reports (and throws for, if enforced):
              // the plain markup goes on, and the policy sees it a second time.
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

    // A popup starts as a blank window of the opener's site that WebKit injects nothing into
    // until its first page loads, and the opener can reach it at once.
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

  protect(window);
  // Also when another copy protected this window already: a blank frame keeps its window, and the
  // marker on it, when its first page loads, but that page's document is a new one.
  watchLoads(document);

  // The parser adds frames through no method the hooks see, and `frames[n]` reaches them past the
  // getters: a blank `<iframe>` in the page's markup stayed a clean window for good. While the page
  // parses, an observer protects them; its records come in before each inline script runs.
  try {
    const MutationObserverCtor = MutationObserver;
    const observe = MutationObserver.prototype.observe;
    const disconnect = MutationObserver.prototype.disconnect;
    const takeRecords = MutationObserver.prototype.takeRecords;
    const addedNodes = member(MutationRecord.prototype, 'addedNodes').get;
    const protectFrame = (frame) => {
      try { protect(read(iframeWindow, frame) || read(frameWindow, frame)); } catch (_) {}
    };
    // A batch holds an element and, in records of their own, the children parsed into it since:
    // only elements whose parent isn't in the batch are searched, as searching each one searched
    // the same nodes once per level they are nested.
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
      // A Trusted Types policy in the markup still applies once a script removes it: kept while
      // it's there for the write hook (see trustedTypesMode).
      if (isTrustedHTML && records.length && !apply(weakMapGet, trustedTypesModes, [document])) {
        try {
          if (hasTrustedTypesMeta(document)) apply(weakMapSet, trustedTypesModes, [document, 'enforce']);
        } catch (_) {}
      }
    };
    const observer = new MutationObserverCtor(parsed);
    apply(observe, observer, [document, { __proto__: null, childList: true, subtree: true }]);
    // Once parsed, the page adds frames only through the hooks.
    apply(addEventListener, document, ['DOMContentLoaded', () => {
      parsed(apply(takeRecords, observer, []));
      apply(disconnect, observer, []);
    }, { __proto__: null, once: true }]);
  } catch (_) {}
})();
