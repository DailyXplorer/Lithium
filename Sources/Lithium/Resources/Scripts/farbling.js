// Brave-style farbling: tiny, deterministic noise per (session, site) so fingerprints
// stay stable on one site but cannot be linked across sites or sessions.
// WebKit's own fingerprinting protections run underneath (see Privacy.swift); this covers
// what they leave: audio, WebGL and offscreen reads, CPU count, voices, and same-origin
// iframes, a classic way to fetch pristine APIs from a fresh window.
(() => {
  'use strict';
  const KEY = '__LITHIUM_SESSION_KEY__';
  // Names the marker below; random too, and independent of KEY, so the marker gives no seed away.
  const MARK_KEY = '__LITHIUM_MARK_KEY__';
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

  // A blank frame (about:blank, srcdoc) belongs to the site that created it.
  const hostname = location.hostname || (() => { try { return parent.location.hostname; } catch (_) { return ''; } })();
  const labels = hostname.split('.');
  const shortSecondLevel = labels.length > 2 && labels.at(-2).length <= 3 && labels.at(-1).length === 2;
  const site = labels.slice(shortSecondLevel ? -3 : -2).join('.');

  const fnv = (text) => {
    let hash = 0x811c9dc5;
    for (const char of text) {
      hash ^= char.charCodeAt(0);
      hash = imul(hash, 0x01000193);
    }
    return hash >>> 0;
  };
  const seed = fnv(KEY + site);

  // HalfSipHash-2-4 of `text` under the 64-bit key `hex`: a keyed hash a page can't run
  // backwards to the key, unlike FNV, whose steps undo one by one.
  const sipHash = (hex, text) => {
    const k0 = parseInt(hex.slice(0, 8), 16) | 0;
    const k1 = parseInt(hex.slice(8, 16), 16) | 0;
    let v0 = k0, v1 = k1, v2 = 0x6c796765 ^ k0, v3 = 0x74656462 ^ k1;
    const rotl = (x, b) => (x << b) | (x >>> (32 - b));
    const rounds = (count) => {
      for (let i = 0; i < count; i++) {
        v0 = (v0 + v1) | 0; v1 = rotl(v1, 5) ^ v0; v0 = rotl(v0, 16);
        v2 = (v2 + v3) | 0; v3 = rotl(v3, 8) ^ v2;
        v0 = (v0 + v3) | 0; v3 = rotl(v3, 7) ^ v0;
        v2 = (v2 + v1) | 0; v1 = rotl(v1, 13) ^ v2; v2 = rotl(v2, 16);
      }
    };
    const word = (m) => { v3 ^= m; rounds(2); v0 ^= m; };
    // Two UTF-16 units a word; the last word carries the length, as in SipHash.
    for (let i = 0; i + 1 < text.length; i += 2) word(text.charCodeAt(i) | (text.charCodeAt(i + 1) << 16));
    word((text.length % 2 ? text.charCodeAt(text.length - 1) : 0) | ((text.length & 0xff) << 24));
    v2 ^= 0xff;
    rounds(4);
    return (v1 ^ v3) >>> 0;
  };
  // Marks a protected window across realms (WebKit's per-frame injection and the iframe hook
  // below can both reach a frame, always one of the same site). A keyed hash of the site: pages
  // can't forge it, and it differs from site to site, so it is no identifier they could share.
  const MARK = '__' + sipHash(MARK_KEY, site).toString(36);
  const prng = (state) => () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = imul(state ^ (state >>> 15), 1 | state);
    t = (t + imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };

  // Setting (not toggling) low bits keeps the noise idempotent: a window reached both by
  // WebKit's per-frame injection and by the iframe hook below gets the same result.
  // One pixel in twenty gets noise. The gaps between them are drawn directly (geometric
  // distribution), so the cost follows the noisy pixels rather than the size of the image.
  const LOG_CLEAN = log(0.95);
  const noisePixels = (data) => {
    const next = prng(seed);
    const gap = () => floor(log(1 - next()) / LOG_CLEAN);
    const pixels = apply(typedLength, data, []) >> 2;
    for (let pixel = gap(); pixel < pixels; pixel += 1 + gap()) {
      data[(pixel << 2) + floor(next() * 3)] |= 1;
    }
  };

  const noiseSamples = (samples) => {
    const length = samples ? apply(typedLength, samples, []) : 0;
    if (length > MAX_SAMPLES) return;
    const next = prng(seed ^ 0x9e3779b9);
    for (let i = 0; i < length; i++) samples[i] += (next() - 0.5) * 1e-7;
  };

  const cores = (real) => max(2, min(real, 2 + floor(prng(seed ^ 0x51ed270b)() * (real - 1))));

  const protect = (win) => {
    if (!win || hasOwn(win, MARK)) return;
    defineProperty(win, MARK, { value: true });

    // Replacements report the original's source through toString, so pages cannot spot them.
    const disguises = new WeakMapCtor();
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

    try {
      const getImageData = patch(win.CanvasRenderingContext2D.prototype, 'getImageData', (target, self, args) => {
        const image = apply(target, self, args);
        if (apply(imageWidth, image, []) * apply(imageHeight, image, []) <= MAX_PIXELS) noisePixels(apply(imageData, image, []));
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
        noisePixels(apply(imageData, image, []));
        apply(putImageData, context, [image, 0, 0]);
        return copy;
      };
      patch(win.HTMLCanvasElement.prototype, 'toDataURL', (target, self, args) => apply(target, farbledCopy(self), args));
      patch(win.HTMLCanvasElement.prototype, 'toBlob', (target, self, args) => apply(target, farbledCopy(self), args));
    } catch (_) {}

    try {
      const offscreenGetImageData = patch(win.OffscreenCanvasRenderingContext2D.prototype, 'getImageData', (target, self, args) => {
        const image = apply(target, self, args);
        if (apply(imageWidth, image, []) * apply(imageHeight, image, []) <= MAX_PIXELS) noisePixels(apply(imageData, image, []));
        return image;
      });
      patch(win.OffscreenCanvas.prototype, 'convertToBlob', (target, self, args) => {
        const width = read(offscreenWidth, self), height = read(offscreenHeight, self);
        if (!width || !height || width * height > MAX_PIXELS) return apply(target, self, args);
        const copy = new OffscreenCanvasCtor(width, height);
        const context = apply(offscreenGetContext, copy, ['2d']);
        apply(offscreenDrawImage, context, [self, 0, 0]);
        const image = apply(offscreenGetImageData, context, [0, 0, width, height]);
        noisePixels(apply(imageData, image, []));
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
          // Byte targets only (Int8Array: WebGL2 integer reads); setting a low bit means nothing to floats.
          if ((kind === 'Uint8Array' || kind === 'Uint8ClampedArray' || kind === 'Int8Array') &&apply(typedLength, pixels, []) <= MAX_PIXELS * 4) noisePixels(pixels);
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
        noiseSamples(args[0]);
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
      try { protect(frame.contentWindow); } catch (_) {}
    };
    // Runs on every DOM insertion of the page, so it does as little as it can: most nodes
    // are elements without children, which cannot hold a frame.
    const protectInserted = (node) => {
      if (node === null || typeof node !== 'object' || node.nodeType !== 1) return;
      const name = node.localName;
      if (name === 'iframe' || name === 'frame') protectFrame(node);
      else if (node.firstElementChild !== null && node.querySelector('iframe, frame') !== null) {
        const found = node.querySelectorAll('iframe, frame');
        for (let i = 0; i < found.length; i++) protectFrame(found[i]);
      }
    };
    // Insertion methods are among the hottest DOM calls: their replacements forward
    // `arguments` instead of collecting them in an array and calling through a handler.
    const hookInsertion = (proto, name, variadic) => {
      const descriptor = proto && getOwnPropertyDescriptor(proto, name);
      if (!descriptor || typeof descriptor.value !== 'function') return;
      const original = descriptor.value;
      const replacement = variadic
        ? { [name]() {
            const result = apply(original, this, arguments);
            for (let i = 0; i < arguments.length; i++) protectInserted(arguments[i]);
            return result;
          } }[name]
        : { [name](node) {
            const result = apply(original, this, arguments);
            protectInserted(node);
            return result;
          } }[name];
      defineProperty(proto, name, { ...descriptor, value: disguise(replacement, original) });
    };
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
      const variadic = ['append', 'prepend', 'after', 'before', 'replaceWith'];
      for (let i = 0; i < variadic.length; i++) hookInsertion(win.Element.prototype, variadic[i], true);
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
})();
