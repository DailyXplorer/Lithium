// Runs in the page's own world: Media Session handlers and detached Audio (Spotify) can only be
// seen from there. The page can post to its channel too, so the app doesn't take an iframe's word
// alone. Reports on media changes or when WebKit starts or stops hearing the page, never on a timer.
(() => {
  const key = Symbol.for('lithium.nowPlaying');
  if (globalThis[key]) return;
  // Taken now, before the page can replace them.
  const channel = globalThis.webkit?.messageHandlers?.lithiumNowPlaying;
  if (!channel) return;
  const post = channel.postMessage.bind(channel);
  const frame = Math.random().toString(36).slice(2);
  const send = (media) => post({ frame, media });
  // A page that wraps its timers (or breaks them) would delay or lose a report.
  const later = setTimeout.bind(globalThis);
  const cancel = clearTimeout.bind(globalThis);
  const session = navigator.mediaSession;
  const handlers = {};
  // Set by the page for the media then active: another media has its own.
  let position = null;
  // Drawn small here, so the app never fetches what the page names.
  let art = { src: null, data: null };
  let active = null;
  // The media last active, still once dropped: WebKit may then hear Web Audio beside it.
  let last = null;
  let reported = false;
  let restored = false;
  let timer = 0;
  // 'heard' or 'silent', as the app tells it, for a page whose sound comes from no media element.
  let sound = null;
  let hadMedia = false;

  const isAudible = (media) => !media.muted && media.volume > 0;
  const isPlaying = (media) => !!media && !media.paused && !media.ended;
  // Without `hadMedia`, the page's sound is not its media's, though Play still plays them.
  const isRunning = () => hadMedia ? isPlaying(active) : sound === 'heard';

  const positionNow = () => position.time + (position.running ? (performance.now() - position.at) / 1000 * position.rate : 0);
  const anchor = () => {
    if (position) position = { ...position, time: positionNow(), at: performance.now(), running: isRunning() };
  };

  const report = () => {
    timer = 0;
    const media = hadMedia ? active : null;
    if (!media && (hadMedia || !sound)) {
      if (reported) send(null);
      reported = false;
      restored = false;
      return;
    }
    const metadata = session?.metadata;
    const paused = media ? media.paused || media.ended : sound === 'silent';
    // A page that sets the position knows it better than its media element (a streamed
    // element's time and duration may span several tracks).
    const time = position ? positionNow() : media?.currentTime ?? 0;
    const duration = position ? position.duration : media?.duration;
    // The page can replace what drawing the picture uses: without it, the player still shows the media.
    let picture = null;
    try { picture = draw(artwork(metadata?.artwork)); } catch {}
    send({
      title: metadata?.title || null,
      artist: metadata?.artist || null,
      artwork: picture,
      paused,
      // Muted while it plays, it keeps its own card but takes no player from another tab.
      audible: media ? isAudible(media) : true,
      time: Number.isFinite(time) ? time : 0,
      duration: Number.isFinite(duration) && duration > 0 ? duration : null,
      rate: media?.playbackRate || 1,
      previous: !!handlers.previoustrack || !!youTubeButton('prev'),
      next: !!handlers.nexttrack || !!youTubeButton('next'),
      restored,
    });
    reported = true;
    restored = false;
  };

  const schedule = () => { timer ||= later(report, 100); };

  // The smallest picture still sharp at the player's size, else the largest there is.
  const artwork = (images) => {
    const sized = [...(images ?? [])].map((image) => {
      const sizes = String(image.sizes ?? '').split(/\s+/).map((size) => parseInt(size, 10) || 0);
      try {
        const url = new URL(image.src, location.href);
        return /^(https?|data|blob):$/.test(url.protocol) ? { url: url.href, size: Math.max(0, ...sizes) } : null;
      } catch { return null; }
    }).filter(Boolean).sort((a, b) => a.size - b.size);
    return (sized.find((image) => image.size >= 96) ?? sized.at(-1))?.url ?? null;
  };

  // Loaded by the page, under its content blocking and without credentials. Without CORS the
  // player shows the tab's icon.
  const draw = (src) => {
    if (src === art.src) return art.data;
    art = { src, data: null };
    if (!src) return null;
    const image = new Image();
    image.crossOrigin = 'anonymous';
    image.onload = () => {
      const side = Math.min(image.naturalWidth, image.naturalHeight);
      if (art.src !== src || !side) return;
      try {
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 96;
        canvas.getContext('2d').drawImage(image, (image.naturalWidth - side) / 2, (image.naturalHeight - side) / 2, side, side, 0, 0, 96, 96);
        const data = canvas.toDataURL('image/jpeg', 0.85);
        if (data.length > 64 * 1024) return;
        art.data = data;
        schedule();
      } catch {}
    };
    image.src = src;
    return null;
  };

  const youTubeButton = (which) => {
    if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return null;
    const button = document.querySelector(`.ytp-${which}-button`);
    return button && button.offsetParent && button.getAttribute('aria-disabled') !== 'true' ? button : null;
  };

  // Media taken out of the document are paused by WebKit but kept loaded, and Play would sound from
  // nothing on screen. A sound never in it (Spotify) stays.
  const attached = new WeakSet();
  const isGone = (media) => attached.has(media) && !media.isConnected && media.paused;
  // Sees a media removed already paused, which fires no event.
  const removals = new MutationObserver(() => {
    if (active && isGone(active)) changed(active, null);
  });

  const changed = (before, media) => {
    active = media;
    last = media ?? before;
    if (position && active !== before) {
      position = position.media && position.media !== active ? null : { ...position, media: active };
    }
    if (active !== before) {
      removals.disconnect();
      if (active && attached.has(active)) {
        removals.observe(document, { childList: true, subtree: true });
        // The document's subtree stops at shadow roots: one in the root that holds the media.
        removals.observe(active.getRootNode(), { childList: true, subtree: true });
      }
    }
    anchor();
    schedule();
  };

  const watched = new WeakSet();
  const onMedia = (event) => {
    const media = event.target;
    if (media.isConnected) attached.add(media);
    let next = active;
    if (media === active && (event.type === 'emptied' && !media.currentSrc || isGone(media))) next = null;
    else if (isPlaying(media) && isAudible(media)) {
      next = media;
      hadMedia = true;
    }
    if (media !== next && next === active) return;
    changed(active, next);
  };
  const watch = (media) => {
    if (!(media instanceof HTMLMediaElement) || watched.has(media)) return;
    watched.add(media);
    for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'durationchange', 'seeked', 'ratechange', 'volumechange']) {
      media.addEventListener(type, onMedia);
    }
  };

  // Detached media are seen only through play(). A media event stops at its shadow root, which
  // gets a listener of its own.
  const onPlay = (event) => {
    if (watched.has(event.target)) return;
    watch(event.target);
    onMedia(event);
  };
  addEventListener('play', onPlay, true);
  const attachShadow = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function () {
    const root = attachShadow.apply(this, arguments);
    root.addEventListener('play', onPlay, true);
    return root;
  };
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    // Held (`hold`), played on its own it would take the sound back from the tab that took it.
    if (held) return Promise.reject(new DOMException('Paused for another tab', 'NotAllowedError'));
    watch(this);
    return play.apply(this, arguments);
  };

  if (session) {
    const proto = Object.getPrototypeOf(session);
    const setActionHandler = proto.setActionHandler;
    proto.setActionHandler = function (action, handler) {
      handlers[action] = typeof handler === 'function' ? handler : null;
      schedule();
      // WebKit calls it itself for a media key, AirPods or Control Center: played again, no longer held.
      const page = handlers[action];
      if (action === 'play' && page) {
        return setActionHandler.call(this, action, function () { playAgain(); return page.apply(this, arguments); });
      }
      return setActionHandler.apply(this, arguments);
    };
    const setPositionState = proto.setPositionState;
    // Kept only once WebKit took it: it throws on a position past the end or a negative one.
    proto.setPositionState = function (state) {
      const result = setPositionState.apply(this, arguments);
      position = state && Number.isFinite(state.position)
        ? { time: state.position, duration: state.duration, rate: state.playbackRate || 1, at: performance.now(), running: isRunning(), media: active }
        : null;
      schedule();
      return result;
    };
    for (const name of ['metadata', 'playbackState']) {
      const property = Object.getOwnPropertyDescriptor(proto, name);
      if (!property?.set) continue;
      Object.defineProperty(proto, name, {
        ...property,
        set(value) {
          property.set.call(this, value);
          schedule();
        },
      });
    }
  }

  // Coming back from the back-forward cache puts it back paused, if no other tab holds the player.
  addEventListener('pagehide', () => {
    cancel(timer);
    timer = 0;
    if (reported) send(null);
    reported = false;
    sound = null;
  });
  addEventListener('pageshow', (event) => {
    if (!event.persisted || !(active?.readyState >= HTMLMediaElement.HAVE_METADATA)) return;
    restored = true;
    schedule();
  });

  // Paused for another tab's sound: WebKit then suspends the page's Web Audio, which a player may
  // resume on its own, unaware why it stopped. Kept suspended until the page is played again.
  let held = false;
  const listen = addEventListener.bind(globalThis);
  const unlisten = removeEventListener.bind(globalThis);
  const release = (event) => { if (event.isTrusted) hold(false); };
  // Each context the page tried to resume while held, with its own resume: it won't ask again.
  const refused = new Map();
  // Kept through a second hold: a context still suspended won't ask again.
  const hold = (on) => {
    held = on;
    for (const type of ['pointerdown', 'keydown']) (on ? listen : unlisten)(type, release, true);
  };
  // Played again (the app, a media key): the page's refused resumes go through. A click leaves them to the page.
  const playAgain = () => {
    hold(false);
    for (const [context, resume] of refused) resume.call(context).catch(() => {});
    refused.clear();
  };
  for (const proto of new Set([globalThis.AudioContext?.prototype, globalThis.webkitAudioContext?.prototype])) {
    const resume = proto?.resume;
    if (resume) {
      proto.resume = function () {
        if (!held) return resume.apply(this, arguments);
        refused.set(this, resume);
        return Promise.resolve();
      };
    }
  }
  // WebKit tells only the page what it hears, so an iframe's Web Audio is never reported: the app
  // is told of it once, to hold it too. Any sound it makes goes to its destination.
  const audio = globalThis.BaseAudioContext?.prototype;
  const destination = globalThis !== globalThis.top && audio && Object.getOwnPropertyDescriptor(audio, 'destination');
  if (destination?.get) {
    let told = false;
    Object.defineProperty(audio, 'destination', {
      ...destination,
      get() {
        if (!told) post({ frame, audio: true });
        told = true;
        return destination.get.call(this);
      },
    });
  }

  const call = (action) => {
    const handler = handlers[action];
    if (!handler) return false;
    try { handler({ action }); } catch {}
    return true;
  };

  // The media's own events report the outcome: a page that pauses later would still say it plays
  // if asked right away.
  Object.defineProperty(globalThis, key, {
    value: (command) => {
      switch (command) {
        // Asked of the page first: a pause it hasn't made yet would otherwise win over the play.
        case 'play': playAgain(); if (!call('play')) active?.play().catch(() => {}); break;
        case 'pause': if (!call('pause')) active?.pause(); break;
        case 'hush': hold(true); if (!call('pause')) active?.pause(); break;
        // Its tab played again from the app: an iframe held with it, which is not the one that plays.
        case 'release': playAgain(); break;
        case 'previous': if (!call('previoustrack')) youTubeButton('prev')?.click(); break;
        case 'next': if (!call('nexttrack')) youTubeButton('next')?.click(); break;
        // WebKit started or stopped hearing the page.
        case 'heard': case 'silent':
          if (sound || command === 'heard') sound = command;
          // Heard while its media is paused, muted or emptied: the sound comes from elsewhere (Web Audio).
          // Media taken out may still be what WebKit hears.
          if (command === 'heard' && last && !isGone(last) && !(isPlaying(active) && isAudible(active))) hadMedia = false;
          anchor();
          schedule();
          break;
      }
    },
  });
})();
