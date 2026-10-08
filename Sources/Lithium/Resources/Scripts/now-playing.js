// Injected by NowPlaying at document start in every frame, in the page's own world: the page's
// Media Session handlers and the sounds it never attaches to the document (Spotify plays a
// detached Audio) can only be seen from there. Its channel is the page's to see and post to as
// well, so the app doesn't take an iframe's word alone. It reports what plays when the media
// changes, never on a timer: for the sidebar's mini player, whose setting only shows or hides
// it, and for one sound at a time, which pauses the tab heard before. It answers the player's
// buttons.
(() => {
  const key = Symbol.for('lithium.nowPlaying');
  if (globalThis[key]) return;
  // Taken now, before the page can replace them.
  const channel = globalThis.webkit?.messageHandlers?.lithiumNowPlaying;
  if (!channel) return;
  const post = channel.postMessage.bind(channel);
  // Tells this frame's reports from its parent's and its siblings'.
  const frame = Math.random().toString(36).slice(2);
  const send = (media) => post({ frame, media });
  const session = navigator.mediaSession;
  const handlers = {};
  // Set by the page for the media then active: another media has its own.
  let position = null;
  // The artwork drawn small here, so the app never fetches what the page names.
  let art = { src: null, data: null };
  // The last media heard: what the player shows and controls.
  let active = null;
  let reported = false;
  let restored = false;
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
      restored = false;
      return;
    }
    const metadata = session?.metadata;
    const paused = active.paused || active.ended;
    // A page that sets the position knows it better than its media element (a streamed
    // element's time and duration may span several tracks).
    const time = position ? positionNow() : active.currentTime;
    const duration = position ? position.duration : active.duration;
    // The page can replace what picking and drawing the picture use (Image, the array methods):
    // without it, the player still shows the media.
    let picture = null;
    try { picture = draw(artwork(metadata?.artwork)); } catch {}
    send({
      title: metadata?.title || null,
      artist: metadata?.artist || null,
      artwork: picture,
      paused,
      // Muted while it plays, it keeps its own card but takes no player from another tab.
      audible: isAudible(active),
      time: Number.isFinite(time) ? time : 0,
      duration: Number.isFinite(duration) && duration > 0 ? duration : null,
      rate: active.playbackRate || 1,
      previous: !!handlers.previoustrack || !!youTubeButton('prev'),
      next: !!handlers.nexttrack || !!youTubeButton('next'),
      restored,
    });
    reported = true;
    restored = false;
  };

  // A burst of media events (a new track fires half a dozen) makes one message.
  const schedule = () => { timer ||= setTimeout(report, 100); };

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

  // Loaded by the page, under its content blocking and without credentials, then drawn into a
  // 96-pixel square sent as a data URL. Until then, or when the page may not read the picture
  // (no CORS), the player shows the tab's icon.
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

  // YouTube's own player buttons, embedded ones included, shown only when there is a track to go to.
  const youTubeButton = (which) => {
    if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return null;
    const button = document.querySelector(`.ytp-${which}-button`);
    return button && button.offsetParent && button.getAttribute('aria-disabled') !== 'true' ? button : null;
  };

  // Media once in the document. Taken out of it (X closing a video), WebKit pauses them but keeps
  // them loaded, and Play would sound from nothing on screen. A sound never in it (Spotify) stays.
  // Still playing out of it, a media was put back, or WebKit lets it be heard.
  const attached = new WeakSet();
  const isGone = (media) => attached.has(media) && !media.isConnected && media.paused;
  // Only while the active media is in the document: it sees one removed already paused, which
  // fires no event.
  const removals = new MutationObserver(() => {
    if (active && isGone(active)) changed(active, null);
  });

  const changed = (before, media) => {
    active = media;
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

  // Media in the document reach a capturing listener; detached ones only through play(). A media
  // event stops at its shadow root (Reddit's player), which gets a listener of its own.
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
        ? { time: state.position, duration: state.duration, rate: state.playbackRate || 1, at: performance.now(), running: isPlaying(active), media: active }
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

  // Leaving the page takes it out of the player. Coming back from the back-forward cache, where
  // WebKit paused its media, puts it back paused, if no other tab holds the player meanwhile.
  addEventListener('pagehide', () => {
    clearTimeout(timer);
    timer = 0;
    if (reported) send(null);
    reported = false;
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

  // The media's own events report the outcome: a page that pauses later (Spotify) would still
  // say it plays if asked right away.
  Object.defineProperty(globalThis, key, {
    value: (command) => {
      switch (command) {
        // Asked of the page even when its media seem there already: a pause it hasn't made yet
        // would otherwise win over the play that follows.
        case 'play': if (!call('play')) active?.play().catch(() => {}); break;
        case 'pause': if (!call('pause')) active?.pause(); break;
        case 'previous': if (!call('previoustrack')) youTubeButton('prev')?.click(); break;
        case 'next': if (!call('nexttrack')) youTubeButton('next')?.click(); break;
      }
    },
  });
})();
