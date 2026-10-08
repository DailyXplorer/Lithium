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
  // frame of a page shares them, and nothing leads from them to the key or another site's.
  const SEED = '__LITHIUM_SEED__';
  // Names the marker below: one per launch key, not per site, so the copies of a popup and of
  // the cross-site frame that opened it still find each other. A page never sees it.
  const MARK = '__LITHIUM_MARK__';
  const MAX_PIXELS = 500000;
  const MAX_SAMPLES = 500000;
  // Taken once: the page shares this world and could replace any of them before a frame or
  // popup it opens is protected (a `call` that always returns true once skipped them), or skew
  // the noise itself (a `Math.floor` that returns a huge gap leaves every pixel clean).
  const apply = Reflect.apply;
  const { hasOwn, defineProperty, getOwnPropertyDescriptor } = Object;
  const { imul, floor, log, max, min } = Math;
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
  const typedArray = Object.getPrototypeOf(Uint8Array.prototype);
  const typedLength = member(typedArray, 'length').get;
  const typedKind = member(typedArray, Symbol.toStringTag).get;
  const imageWidth = member(ImageData.prototype, 'width').get;
  const imageHeight = member(ImageData.prototype, 'height').get;
  const imageData = member(ImageData.prototype, 'data').get;
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
  const regExpExec = RegExp.prototype.exec;
  const FRAME_TAG = /frame/i;
  // Documents with no response of their own, which take their creator's policies.
  const NO_RESPONSE = /^(about|blob|data):/i;
  const TRUSTED_TYPES_META = 'head meta[http-equiv="content-security-policy" i][content*="require-trusted-types-for" i]';

  // sfc32 over the seed's 128 bits with `salt` mixed in: too much state to search from a few
  // noisy pixels, unlike the 32 bits it once had. The first outputs are dropped to spread the salt.
  const seedWords = [0, 8, 16, 24].map((at) => parseInt(SEED.slice(at, at + 8), 16) | 0);
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

  // A hash of the image read, so where the noise goes changes with the image: a blank canvas
  // shows a page nothing of where it lands in another. Four bytes at a time where they line up.
  const Uint32ArrayCtor = Uint32Array;
  const typedBuffer = member(typedArray, 'buffer').get;
  const typedOffset = member(typedArray, 'byteOffset').get;
  const hashBytes = (data, length) => {
    let hash = length ^ 0x811c9dc5, done = 0;
    try {
      const count = length >> 2;
      const words = new Uint32ArrayCtor(apply(typedBuffer, data, []), apply(typedOffset, data, []), count);
      for (let i = 0; i < count; i++) hash = imul(hash ^ words[i], 0x01000193);
      done = count << 2;
    } catch (_) {}
    for (let i = done; i < length; i++) hash = imul(hash ^ data[i], 0x01000193);
    return hash;
  };

  // One pixel in twenty moves a color by one, up or down: unlike setting a low bit, nothing
  // as simple as clearing one undoes it. The gaps between them are drawn directly (geometric
  // distribution), so past the hash the cost follows the noisy pixels. A window gets this once
  // (the marker below), so the noise needn't hold when applied twice.
  // Pixels this handed out and the page reads back (put back, or drawn from a data URL) are
  // left as they are: noised afresh at other spots each round trip, an editor's canvas would
  // drift into visible grain. The hashes of the last few results are kept for exact round trips,
  // and the last result of each context and region for those that change part of the image first
  // (a fill, a brush dab): the pixels the page left alone aren't noised again. Either way the page
  // only gets back values it was already given.
  const LOG_CLEAN = log(0.95);
  const NOISED = 64;
  const noised = new Int32Array(NOISED);
  let noisedCount = 0;
  const Uint8ArrayCtor = Uint8Array;
  const lastResults = new WeakMapCtor();
  // `owner` and `region` (a string, or null when unknown) say where the pixels were read.
  const noisePixels = (data, owner, region) => {
    const length = apply(typedLength, data, []);
    const hash = hashBytes(data, length);
    let bytes = null, last = null;
    try {
      bytes = new Uint8ArrayCtor(apply(typedBuffer, data, []), apply(typedOffset, data, []), length);
      if (region !== null) last = apply(weakMapGet, lastResults, [owner]) || null;
    } catch (_) {}
    const before = last !== null && last.region === region && last.length === length ? last.bytes : null;
    let fresh = true;
    for (let i = 0; i < noisedCount && i < NOISED; i++) if (noised[i] === hash) fresh = false;
    if (fresh) {
      const next = prng(hash);
      const gap = () => floor(log(1 - next()) / LOG_CLEAN);
      const pixels = length >> 2;
      for (let pixel = gap(); pixel < pixels; pixel += 1 + gap()) {
        const at = (pixel << 2) + floor(next() * 3);
        const value = data[at], step = next() < 0.5 ? 1 : -1;
        const start = pixel << 2;
        if (before !== null && bytes[start] === before[start] && bytes[start + 1] === before[start + 1] &&
            bytes[start + 2] === before[start + 2] && bytes[start + 3] === before[start + 3]) continue;
        data[at] = value + step;
        // At either end of the range the write clamps or wraps: go the other way.
        if (data[at] !== value + step) data[at] = value - step;
      }
      noised[noisedCount++ % NOISED] = hashBytes(data, length);
    }
    try {
      if (bytes !== null && region !== null) {
        apply(weakMapSet, lastResults, [owner, { __proto__: null, region, length, bytes: new Uint8ArrayCtor(bytes) }]);
      }
    } catch (_) {}
  };
  // Where a read comes from, when the page passed plain numbers: anything else could convert
  // differently each time it is asked.
  const regionOf = (args) => {
    for (let i = 0; i < 4; i++) if (typeof args[i] !== 'number') return null;
    return args[0] + ',' + args[1] + ',' + args[2] + ',' + args[3];
  };

  const noiseSamples = (samples) => {
    const length = samples ? apply(typedLength, samples, []) : 0;
    if (length > MAX_SAMPLES) return;
    const next = prng(0x9e3779b9);
    for (let i = 0; i < length; i++) samples[i] += (next() - 0.5) * 1e-7;
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
      const getImageData = patch(win.CanvasRenderingContext2D.prototype, 'getImageData', (target, self, args) => {
        const image = apply(target, self, args);
        if (apply(imageWidth, image, []) * apply(imageHeight, image, []) <= MAX_PIXELS) noisePixels(apply(imageData, image, []), self, regionOf(args));
        return image;
      });
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
        noisePixels(apply(imageData, image, []), canvas, width + ',' + height);
        apply(putImageData, context, [image, 0, 0]);
        return copy;
      };
      patch(win.HTMLCanvasElement.prototype, 'toDataURL', (target, self, args) => apply(target, farbledCopy(self), args));
      patch(win.HTMLCanvasElement.prototype, 'toBlob', (target, self, args) => apply(target, farbledCopy(self), args));
    } catch (_) {}

    try {
      const offscreenGetImageData = patch(win.OffscreenCanvasRenderingContext2D.prototype, 'getImageData', (target, self, args) => {
        const image = apply(target, self, args);
        if (apply(imageWidth, image, []) * apply(imageHeight, image, []) <= MAX_PIXELS) noisePixels(apply(imageData, image, []), self, regionOf(args));
        return image;
      });
      patch(win.OffscreenCanvas.prototype, 'convertToBlob', (target, self, args) => {
        const width = read(offscreenWidth, self), height = read(offscreenHeight, self);
        if (!width || !height || width * height > MAX_PIXELS) return apply(target, self, args);
        const copy = new OffscreenCanvasCtor(width, height);
        const context = apply(offscreenGetContext, copy, ['2d']);
        apply(offscreenDrawImage, context, [self, 0, 0]);
        const image = apply(offscreenGetImageData, context, [0, 0, width, height]);
        noisePixels(apply(imageData, image, []), self, width + ',' + height);
        apply(offscreenPutImageData, context, [image, 0, 0]);
        return apply(target, copy, args);
      });
    } catch (_) {}

    try {
      // Indexed loops here and below: the page may have replaced the array iterator by now.
      const contexts = [win.WebGLRenderingContext, win.WebGL2RenderingContext];
      for (let i = 0; i < contexts.length; i++) {
        patch(contexts[i] && contexts[i].prototype, 'readPixels', (target, self, args) => {
          const result = apply(target, self, args);
          const pixels = args[6];
          const kind = pixels ? apply(typedKind, pixels, []) : undefined;
          // Byte targets only (Int8Array: WebGL2 integer reads); a step of one means nothing to floats.
          if ((kind === 'Uint8Array' || kind === 'Uint8ClampedArray' || kind === 'Int8Array') &&apply(typedLength, pixels, []) <= MAX_PIXELS * 4) noisePixels(pixels, self, regionOf(args));
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
          noiseSamples(samples);
        }
        return samples;
      });
      patch(win.AudioBuffer.prototype, 'copyFromChannel', (target, self, args) => {
        const result = apply(target, self, args);
        noiseSamples(args[0]);
        return result;
      });
      patch(win.AnalyserNode.prototype, 'getFloatFrequencyData', (target, self, args) => {
        const result = apply(target, self, args);
        noiseFrequencies(args[0]);
        return result;
      });
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
    // are elements without children, which cannot hold a frame.
    const protectInserted = (node) => {
      if (node === null || typeof node !== 'object' || node.nodeType !== 1) return;
      const name = node.localName;
      if (name === 'iframe' || name === 'frame') protectFrame(node);
      else if (node.firstElementChild !== null && node.querySelector('iframe, frame') !== null) protectAll(framesIn(node));
    };
    // A fragment hands its children over on insertion, so its frames are listed before.
    const framesBefore = (node) => node !== null && typeof node === 'object' && node.nodeType === 11 ? framesIn(node) : null;
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
        if (args.length > 2) { try { protect(result); } catch (_) {} } else remark(self);
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
            if (mode !== 'enforce' && read(nodeCount, apply(queryAll[9], doc, [TRUSTED_TYPES_META]))) {
              mode = 'enforce';
              apply(weakMapSet, trustedTypesModes, [doc, mode]);
            }
          } catch (_) {}
          if (mode || !realm || !apply(regExpExec, NO_RESPONSE, [`${read(documentURL, doc)}`])) return mode;
          let creator = null;
          try { creator = view.parent !== view ? view.parent : view.opener; } catch (_) {}
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
        const child = apply(target, self == null ? win : self, args);
        try { protect(child); } catch (_) {}
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
    const localName = member(Element.prototype, 'localName').get;
    const firstElementChild = member(Element.prototype, 'firstElementChild').get;
    const protectFrame = (frame) => {
      try { protect(read(iframeWindow, frame) || read(frameWindow, frame)); } catch (_) {}
    };
    const parsed = (records) => {
      for (let i = 0; i < records.length; i++) {
        const added = read(addedNodes, records[i]);
        const count = added ? read(nodeCount, added) : 0;
        for (let j = 0; j < count; j++) {
          const node = added[j];
          if (read(nodeType, node) !== 1) continue;
          const name = read(localName, node);
          if (name === 'iframe' || name === 'frame') protectFrame(node);
          else if (read(firstElementChild, node)) {
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
          if (read(nodeCount, apply(queryAll[9], document, [TRUSTED_TYPES_META]))) apply(weakMapSet, trustedTypesModes, [document, 'enforce']);
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
