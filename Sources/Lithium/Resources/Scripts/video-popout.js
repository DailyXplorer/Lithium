// Body of an async function run by VideoPopout in Lithium's own content world.
// Arguments: command, and value for "seek" and "mute".
// The popped out video goes into the top layer (a manual popover) and fills the viewport, so
// the tab's web view, shrunk to the mini player, shows only the video. The page keeps its own
// player: nothing is moved or reloaded, and the video never stops.

const store = globalThis.lithiumVideoPopout ??= { video: null, style: null, addedPopover: false };
const mark = 'data-lithium-popout';

const isPlaying = (video) => !video.paused && !video.ended && video.readyState > 2;
const isAudible = (video) => !video.muted && video.volume > 0;
const area = (video) => {
  const rect = video.getBoundingClientRect();
  return rect.width * rect.height;
};

// The one worth watching: playing before paused, with sound before muted, then the largest.
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
  // A live stream has no end.
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
  if (!video.hasAttribute('popover')) {
    video.popover = 'manual';
    store.addedPopover = true;
  }
  if (!video.matches(':popover-open')) video.showPopover();
  return state(video);
};

const hide = () => {
  const video = store.video;
  store.video = null;
  store.style?.remove();
  if (!video) return;
  if (video.matches(':popover-open')) video.hidePopover();
  if (store.addedPopover) video.removeAttribute('popover');
  store.addedPopover = false;
  video.removeAttribute(mark);
};

switch (command) {
  // Whether leaving the tab should pop its video out: one is playing, with sound, big enough
  // to be what the user watches (not a muted loop or a thumbnail preview).
  case 'playing': {
    const video = best();
    return !!video && isPlaying(video) && isAudible(video) && area(video) >= 200 * 112;
  }
  case 'show': return show();
  case 'hide': hide(); return null;
  case 'state': return state(store.video);
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
