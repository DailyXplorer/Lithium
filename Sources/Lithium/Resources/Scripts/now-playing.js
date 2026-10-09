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
  let reported = false;
  let restored = false;
  let timer = 0;
  // 'heard' or 'silent', as the app tells it, for a page whose sound comes from no media element.
  let sound = null;
  let hadMedia = false;

  const isAudible = (media) => !media.muted && media.volume > 0;
  const isPlaying = (media) => !!media && !media.paused && !media.ended;
  const isRunning = () => active ? isPlaying(active) : !hadMedia && sound === 'heard';

  const positionNow = () => position.time + (position.running ? (performance.now() - position.at) / 1000 * position.rate : 0);
  const anchor = () => {
    if (position) position = { ...position, time: positionNow(), at: performance.now(), running: isRunning() };
  };

  const report = () => {
    timer = 0;
    if (!active && (hadMedia || !sound)) {
      if (reported) send(null);
      reported = false;
      restored = false;
      return;
    }
    const metadata = session?.metadata;
    const paused = active ? active.paused || active.ended : sound === 'silent';
    // A page that sets the position knows it better than its media element (a streamed
    // element's time and duration may span several tracks).
    const time = position ? positionNow() : active?.currentTime ?? 0;
    const duration = position ? position.duration : active?.duration;
    // The page can replace what drawing the picture uses: without it, the player still shows the media.
    let picture = null;
    try { picture = draw(artwork(metadata?.artwork)); } catch {}
    send({
      title: metadata?.title || null,
      artist: metadata?.artist || null,
      artwork: picture,
      paused,
      // Muted while it plays, it keeps its own card but takes no player from another tab.
      audible: active ? isAudible(active) : true,
      time: Number.isFinite(time) ? time : 0,
      duration: Number.isFinite(duration) && duration > 0 ? duration : null,
      rate: active?.playbackRate || 1,
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
    if (media) hadMedia = true;
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
    else if (isPlaying(media) && isAudible(media)) next = media;
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
    watch(this);
    return play.apply(this, arguments);
  };

  if (session) {
    const proto = Object.getPrototypeOf(session);
    const setActionHandler = proto.setActionHandler;
    proto.setActionHandler = function (action, handler) {
      handlers[action] = typeof handler === 'function' ? handler : null;
      schedule();
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
        case 'play': if (!call('play')) active?.play().catch(() => {}); break;
        case 'pause': if (!call('pause')) active?.pause(); break;
        case 'previous': if (!call('previoustrack')) youTubeButton('prev')?.click(); break;
        case 'next': if (!call('nexttrack')) youTubeButton('next')?.click(); break;
        // WebKit started or stopped hearing the page.
        case 'heard': case 'silent':
          if (sound || command === 'heard') sound = command;
          anchor();
          schedule();
          break;
      }
    },
  });
})();
