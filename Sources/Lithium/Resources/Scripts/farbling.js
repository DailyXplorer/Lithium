// Brave-style farbling: tiny, deterministic noise per (session, site) so fingerprints
// stay stable on one site but cannot be linked across sites or sessions.
// WebKit's own fingerprinting protections run underneath (see Privacy.swift); this covers
// what they leave: audio, WebGL and offscreen reads, CPU count, voices, and same-origin
// iframes, a classic way to fetch pristine APIs from a fresh window.
(() => {
  'use strict';
  const KEY = '__LITHIUM_SESSION_KEY__';
  const MAX_PIXELS = 500000;
  const MAX_SAMPLES = 500000;
  // Taken once: the page shares this world and could replace Reflect.apply later.
  const apply = Reflect.apply;

  // A blank frame (about:blank, srcdoc) belongs to the site that created it.
  const hostname = location.hostname || (() => { try { return parent.location.hostname; } catch (_) { return ''; } })();
  const labels = hostname.split('.');
  const shortSecondLevel = labels.length > 2 && labels.at(-2).length <= 3 && labels.at(-1).length === 2;
  const site = labels.slice(shortSecondLevel ? -3 : -2).join('.');

  const fnv = (text) => {
    let hash = 0x811c9dc5;
    for (const char of text) {
      hash ^= char.charCodeAt(0);
      hash = Math.imul(hash, 0x01000193);
    }
    return hash >>> 0;
  };
  const seed = fnv(KEY + site);
  // Marks a protected window across realms (WebKit's per-frame injection and the iframe hook
  // below can both reach a frame). The name derives from the session key, so pages can't forge it.
  const MARK = '__' + fnv(KEY).toString(36);
  const prng = (state) => () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };

  // Setting (not toggling) low bits keeps the noise idempotent: a window reached both by
  // WebKit's per-frame injection and by the iframe hook below gets the same result.
  // One pixel in twenty gets noise. The gaps between them are drawn directly (geometric
  // distribution), so the cost follows the noisy pixels rather than the size of the image.
  const LOG_CLEAN = Math.log(0.95);
  const noisePixels = (data) => {
    const next = prng(seed);
    const gap = () => Math.floor(Math.log(1 - next()) / LOG_CLEAN);
    const pixels = data.length >> 2;
    for (let pixel = gap(); pixel < pixels; pixel += 1 + gap()) {
      data[(pixel << 2) + Math.floor(next() * 3)] |= 1;
    }
  };

  const noiseSamples = (samples) => {
    if (!samples || samples.length > MAX_SAMPLES) return;
    const next = prng(seed ^ 0x9e3779b9);
    for (let i = 0; i < samples.length; i++) samples[i] += (next() - 0.5) * 1e-7;
  };

  const cores = (real) => Math.max(2, Math.min(real, 2 + Math.floor(prng(seed ^ 0x51ed270b)() * (real - 1))));

  const protect = (win) => {
    if (!win || Object.prototype.hasOwnProperty.call(win, MARK)) return;
    Object.defineProperty(win, MARK, { value: true });

    // Replacements report the original's source through toString, so pages cannot spot them.
    const disguises = new WeakMap();
    const nativeToString = win.Function.prototype.toString;
    const disguise = (replacement, original) => {
      Object.defineProperty(replacement, 'name', { value: original.name });
      Object.defineProperty(replacement, 'length', { value: original.length });
      disguises.set(replacement, original);
      return replacement;
    };
    const toString = disguise({ toString() { return apply(nativeToString, disguises.get(this) || this, []); } }.toString, nativeToString);
    Object.defineProperty(win.Function.prototype, 'toString', { ...Object.getOwnPropertyDescriptor(win.Function.prototype, 'toString'), value: toString });

    const patch = (proto, name, handler) => {
      const descriptor = proto && Object.getOwnPropertyDescriptor(proto, name);
      if (!descriptor || typeof descriptor.value !== 'function') return null;
      const original = descriptor.value;
      const value = disguise({ [name](...args) { return handler(original, this, args); } }[name], original);
      Object.defineProperty(proto, name, { ...descriptor, value });
      return original;
    };

    const patchGetter = (proto, name, handler) => {
      const descriptor = proto && Object.getOwnPropertyDescriptor(proto, name);
      if (!descriptor || !descriptor.get) return;
      const original = descriptor.get;
      const get = disguise({ get [name]() { return handler(original, this); } }.__lookupGetter__(name), original);
      Object.defineProperty(proto, name, { ...descriptor, get });
    };

    try {
      const getImageData = patch(win.CanvasRenderingContext2D.prototype, 'getImageData', (target, self, args) => {
        const image = apply(target, self, args);
        if (image.width * image.height <= MAX_PIXELS) noisePixels(image.data);
        return image;
      });
      const farbledCopy = (canvas) => {
        const { width, height } = canvas;
        if (!width || !height || width * height > MAX_PIXELS) return canvas;
        const copy = win.document.createElement('canvas');
        copy.width = width;
        copy.height = height;
        const context = copy.getContext('2d');
        context.drawImage(canvas, 0, 0);
        const image = apply(getImageData, context, [0, 0, width, height]);
        noisePixels(image.data);
        context.putImageData(image, 0, 0);
        return copy;
      };
      for (const name of ['toDataURL', 'toBlob']) {
        patch(win.HTMLCanvasElement.prototype, name, (target, self, args) => apply(target, farbledCopy(self), args));
      }
    } catch (_) {}

    try {
      const offscreenGetImageData = patch(win.OffscreenCanvasRenderingContext2D.prototype, 'getImageData', (target, self, args) => {
        const image = apply(target, self, args);
        if (image.width * image.height <= MAX_PIXELS) noisePixels(image.data);
        return image;
      });
      patch(win.OffscreenCanvas.prototype, 'convertToBlob', (target, self, args) => {
        const { width, height } = self;
        if (!width || !height || width * height > MAX_PIXELS) return apply(target, self, args);
        const copy = new win.OffscreenCanvas(width, height);
        const context = copy.getContext('2d');
        context.drawImage(self, 0, 0);
        const image = apply(offscreenGetImageData, context, [0, 0, width, height]);
        noisePixels(image.data);
        context.putImageData(image, 0, 0);
        return apply(target, copy, args);
      });
    } catch (_) {}

    try {
      for (const context of [win.WebGLRenderingContext, win.WebGL2RenderingContext]) {
        patch(context && context.prototype, 'readPixels', (target, self, args) => {
          const result = apply(target, self, args);
          const pixels = args[6];
          if (pixels && pixels.BYTES_PER_ELEMENT === 1 && pixels.length <= MAX_PIXELS * 4) noisePixels(pixels);
          return result;
        });
      }
    } catch (_) {}

    try {
      const farbled = new WeakSet();
      patch(win.AudioBuffer.prototype, 'getChannelData', (target, self, args) => {
        const samples = apply(target, self, args);
        if (!farbled.has(samples)) {
          farbled.add(samples);
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
        const language = (win.navigator.language || 'en').split('-')[0].toLowerCase();
        return apply(target, self, args).filter((voice) =>
          voice.default || (voice.localService && voice.lang.toLowerCase().startsWith(language)));
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
        node.querySelectorAll('iframe, frame').forEach(protectFrame);
      }
    };
    // Insertion methods are among the hottest DOM calls: their replacements forward
    // `arguments` instead of collecting them in an array and calling through a handler.
    const hookInsertion = (proto, name, variadic) => {
      const descriptor = proto && Object.getOwnPropertyDescriptor(proto, name);
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
      Object.defineProperty(proto, name, { ...descriptor, value: disguise(replacement, original) });
    };
    try {
      for (const proto of [win.HTMLIFrameElement.prototype, win.HTMLFrameElement.prototype]) {
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
      for (const name of ['appendChild', 'insertBefore', 'replaceChild']) hookInsertion(win.Node.prototype, name, false);
      for (const name of ['append', 'prepend', 'after', 'before', 'replaceWith']) hookInsertion(win.Element.prototype, name, true);
    } catch (_) {}
  };

  protect(window);
})();
