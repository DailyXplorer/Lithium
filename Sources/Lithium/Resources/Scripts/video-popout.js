// Body of an async function run by VideoPopout in Lithium's own content world.
// Arguments: command, and value for "seek", "mute" and "state".
// The video goes into the top layer (a manual popover) and fills the shrunk web view: nothing is
// moved or reloaded, so it never stops.

const store = globalThis.lithiumVideoPopout ??= { video: null, style: null, addedPopover: false };
const mark = 'data-lithium-popout';

const isPlaying = (video) => !video.paused && !video.ended && video.readyState > 2;
const isAudible = (video) => !video.muted && video.volume > 0;
const area = (video) => {
  const rect = video.getBoundingClientRect();
  return rect.width * rect.height;
};

const best = () => {
  const rank = (video) => [isPlaying(video), isAudible(video), area(video)];
  const before = (a, b) => {
    const [x, y] = [rank(a), rank(b)];
    for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] > y[i] ? -1 : 1;
    return 0;
  };
  return [...document.querySelectorAll('video')]
    .filter((video) => video.readyState > 0 && video.videoWidth > 0)
    .sort(before)[0] ?? null;
};

const state = (video) => video && video.isConnected ? {
  paused: video.paused || video.ended,
  time: video.currentTime,
  duration: Number.isFinite(video.duration) ? video.duration : null,
  muted: !isAudible(video),
  width: video.videoWidth,
  height: video.videoHeight,
} : null;

const css = `
  video[${mark}] {
    position: fixed !important; inset: 0 !important; display: block !important;
    width: 100vw !important; height: 100vh !important; min-width: 0 !important; min-height: 0 !important;
    max-width: none !important; max-height: none !important;
    margin: 0 !important; padding: 0 !important; border: 0 !important; border-radius: 0 !important;
    transform: none !important; translate: none !important; scale: none !important; rotate: none !important;
    clip-path: none !important; filter: none !important; opacity: 1 !important; visibility: visible !important;
    object-fit: contain !important; background: #000 !important;
  }
  video[${mark}]::backdrop { background: #000; }
`;

const show = () => {
  const video = best();
  if (!video) return null;
  if (store.video !== video) hide();
  store.video = video;
  video.setAttribute(mark, '');
  store.style ??= Object.assign(document.createElement('style'), { textContent: css });
  (document.head || document.documentElement).append(store.style);
  raise(video);
  keepRaised(video);
  return state(video);
};

// Never throws: on the regular state check, an error would close the mini player.
const raise = (video) => {
  if (!video.isConnected || video.matches(':popover-open')) return;
  // The page may drop the attribute when it redraws its player.
  if (!video.hasAttribute('popover')) {
    video.popover = 'manual';
    store.addedPopover = true;
  }
  try { video.showPopover(); } catch {}
};

// Removing an element closes its popover: YouTube moves its player when its window narrows.
// Every frame, the video goes back up. Paused, the loop stops until it plays again: the state
// check raises it meanwhile.
const keepRaised = (video) => {
  cancelAnimationFrame(store.frame);
  store.frame = 0;
  const check = () => {
    if (store.video !== video) return;
    raise(video);
    if (video.paused) {
      store.frame = 0;
      video.addEventListener('play', () => { if (store.video === video && !store.frame) keepRaised(video); }, { once: true });
      return;
    }
    store.frame = requestAnimationFrame(check);
  };
  store.frame = requestAnimationFrame(check);
};

// Resolves when a paused video plays, seeks, changes sound or source, or the page resizes it,
// and at the latest after `ms`: nothing else changes what the player shows.
const changeOf = (video, ms) => new Promise((resolve) => {
  const events = ['play', 'seeked', 'volumechange', 'emptied', 'resize'];
  const done = () => {
    clearTimeout(timer);
    events.forEach((type) => video.removeEventListener(type, done));
    removeEventListener('resize', done);
    resolve();
  };
  const timer = setTimeout(done, ms);
  events.forEach((type) => video.addEventListener(type, done));
  addEventListener('resize', done);
});

const hide = () => {
  const video = store.video;
  store.video = null;
  cancelAnimationFrame(store.frame);
  store.frame = 0;
  store.style?.remove();
  if (!video) return;
  if (video.matches(':popover-open')) video.hidePopover();
  if (store.addedPopover) video.removeAttribute('popover');
  store.addedPopover = false;
  video.removeAttribute(mark);
};

switch (command) {
  // Not a muted loop or a thumbnail preview.
  case 'playing': {
    const video = best();
    return !!video && isPlaying(video) && isAudible(video) && area(video) >= 200 * 112;
  }
  case 'show': return show();
  case 'hide': hide(); return null;
  case 'state': {
    if (store.video) raise(store.video);
    // `value` (ms): a paused video answers once it changes, so the app doesn't ask twice a second.
    const video = store.video;
    if (value > 0 && video?.isConnected && (video.paused || video.ended)) {
      await changeOf(video, value);
      if (store.video) raise(store.video);
    }
    return state(store.video);
  }
}

const video = store.video;
if (!video?.isConnected) return null;
switch (command) {
  case 'play': await video.play().catch(() => {}); break;
  case 'pause': video.pause(); break;
  case 'seek': video.currentTime = Math.max(0, Math.min(value, video.duration || value)); break;
  case 'mute':
    video.muted = value;
    if (!value && video.volume === 0) video.volume = 1;
    break;
}
return state(video);
