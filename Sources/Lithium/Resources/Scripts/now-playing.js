// Injected by NowPlaying at document start, in the page's own world: the page's Media Session
// handlers and the sounds it never attaches to the document (Spotify plays a detached Audio)
// can only be seen from there. It reports what plays to the sidebar's mini player when the
// media changes, never on a timer, and answers the player's buttons.
(() => {
  const key = Symbol.for('lithium.nowPlaying');
  if (globalThis[key]) return;
  // Taken now, before the page can replace them.
  const channel = globalThis.webkit?.messageHandlers?.lithiumNowPlaying;
  if (!channel) return;
  const send = channel.postMessage.bind(channel);
  const session = navigator.mediaSession;
  const handlers = {};
  let position = null;
  // The last media heard: what the player shows and controls.
  let active = null;
  let reported = false;
  let timer = 0;

  const isAudible = (media) => !media.muted && media.volume > 0;
  const isPlaying = (media) => !!media && !media.paused && !media.ended;

  // The page sets the position once in a while; in between it runs while the media plays.
  const positionNow = () => position.time + (position.running ? (performance.now() - position.at) / 1000 * position.rate : 0);
  const anchor = () => {
    if (position) position = { ...position, time: positionNow(), at: performance.now(), running: isPlaying(active) };
  };

  const report = () => {
    timer = 0;
    if (!active) {
      if (reported) send(null);
      reported = false;
      return;
    }
    const metadata = session?.metadata;
    const paused = active.paused || active.ended;
    // A page that sets the position knows it better than its media element (a streamed
    // element's time and duration may span several tracks).
    const time = position ? positionNow() : active.currentTime;
    const duration = position ? position.duration : active.duration;
    send({
      title: metadata?.title || null,
      artist: metadata?.artist || null,
      artwork: artwork(metadata?.artwork),
      paused,
      time: Number.isFinite(time) ? time : 0,
      duration: Number.isFinite(duration) && duration > 0 ? duration : null,
      rate: active.playbackRate || 1,
      previous: !!handlers.previoustrack || !!youTubeButton('prev'),
      next: !!handlers.nexttrack || !!youTubeButton('next'),
    });
    reported = true;
  };

  // A burst of media events (a new track fires half a dozen) makes one message.
  const schedule = () => { timer ||= setTimeout(report, 100); };

  // The smallest picture still sharp at the player's size, else the largest there is.
  const artwork = (images) => {
    const sized = [...(images ?? [])].map((image) => {
      const sizes = String(image.sizes ?? '').split(/\s+/).map((size) => parseInt(size, 10) || 0);
      try {
        const url = new URL(image.src, location.href);
        return /^https?:$/.test(url.protocol) ? { url: url.href, size: Math.max(0, ...sizes) } : null;
      } catch { return null; }
    }).filter(Boolean).sort((a, b) => a.size - b.size);
    return (sized.find((image) => image.size >= 96) ?? sized.at(-1))?.url ?? null;
  };

  // YouTube's own player buttons, shown only when there is a track to go to.
  const youTubeButton = (which) => {
    if (!/(^|\.)youtube\.com$/.test(location.hostname)) return null;
    const button = document.querySelector(`.ytp-${which}-button`);
    return button && button.offsetParent && button.getAttribute('aria-disabled') !== 'true' ? button : null;
  };

  const watched = new WeakSet();
  const onMedia = (event) => {
    const media = event.target;
    const before = active;
    if (event.type === 'emptied' && media === active && !media.currentSrc) active = null;
    else if (isPlaying(media) && isAudible(media)) active = media;
    if (media !== active && active === before) return;
    anchor();
    schedule();
  };
  const watch = (media) => {
    if (!(media instanceof HTMLMediaElement) || watched.has(media)) return;
    watched.add(media);
    for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'durationchange', 'seeked', 'ratechange', 'volumechange']) {
      media.addEventListener(type, onMedia);
    }
  };

  // Media in the document reach a capturing listener; detached ones only through play().
  addEventListener('play', (event) => {
    if (watched.has(event.target)) return;
    watch(event.target);
    onMedia(event);
  }, true);
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
    proto.setPositionState = function (state) {
      position = state && Number.isFinite(state.position)
        ? { time: state.position, duration: state.duration, rate: state.playbackRate || 1, at: performance.now(), running: isPlaying(active) }
        : null;
      schedule();
      return setPositionState.apply(this, arguments);
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

  // Leaving the page takes it out of the player; coming back from the back-forward cache
  // puts it back.
  addEventListener('pagehide', () => {
    clearTimeout(timer);
    timer = 0;
    if (reported) send(null);
    reported = false;
  });
  addEventListener('pageshow', (event) => { if (event.persisted && active) schedule(); });

  const call = (action) => {
    const handler = handlers[action];
    if (!handler) return false;
    try { handler({ action }); } catch {}
    return true;
  };

  Object.defineProperty(globalThis, key, {
    value: (command) => {
      switch (command) {
        case 'toggle': {
          const playing = isPlaying(active);
          if (!call(playing ? 'pause' : 'play') && active) {
            if (playing) active.pause(); else active.play().catch(() => {});
          }
          break;
        }
        case 'previous': if (!call('previoustrack')) youTubeButton('prev')?.click(); break;
        case 'next': if (!call('nexttrack')) youTubeButton('next')?.click(); break;
      }
      schedule();
    },
  });
})();
