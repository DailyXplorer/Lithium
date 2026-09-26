// SponsorBlock on YouTube. Runs in Lithium's "SponsorBlock" content world: YouTube's code
// shares the DOM with it but cannot see its variables or its line to the app.
(() => {
  const bridge = window.webkit?.messageHandlers?.sponsorBlock;
  if (!bridge || window.top !== window) return;

  // Segments submitted for another cut of the video (longer or shorter than this one) are off.
  const DURATION_TOLERANCE = 3;
  const NOTICE_SECONDS = 5;

  let videoID = null;
  let segments = [];
  let request = 0;
  let video = null;
  let timer = 0;
  let noticeTimer = 0;
  const unskipped = new Set();

  const idFrom = (href) => {
    try {
      const url = new URL(href, location.href);
      const id = url.pathname === '/watch'
        ? url.searchParams.get('v')
        : url.pathname.match(/^\/(?:shorts|live|embed)\/([\w-]{11})(?:\/|$)/)?.[1];
      return /^[\w-]{11}$/.test(id ?? '') ? id : null;
    } catch {
      return null;
    }
  };

  const playerOf = (element) => element?.closest?.('#movie_player, #shorts-player') ?? null;
  const isPlayerVideo = (target) => target instanceof HTMLVideoElement && playerOf(target) !== null;
  const adShowing = () => playerOf(video)?.classList.contains('ad-showing') ?? false;
  const fits = (segment) => !(segment.duration > 0 && Number.isFinite(video.duration)
    && Math.abs(segment.duration - video.duration) > DURATION_TOLERANCE);
  const active = (segment) => fits(segment) && !unskipped.has(segment.id);

  // The overlay lives in a closed shadow root inside the player, so it follows it into
  // fullscreen and YouTube's styles never reach it.
  const host = document.createElement('div');
  const shadow = host.attachShadow({ mode: 'closed' });
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(`
    :host { all: initial; position: absolute; right: 12px; bottom: 72px; z-index: 70;
      display: flex; flex-direction: column; align-items: flex-end; gap: 8px; pointer-events: none;
      font: 500 13px/1 "YouTube Sans", Roboto, -apple-system, sans-serif; }
    .pill { display: none; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 18px;
      background: rgba(15, 15, 15, .82); color: #fff; pointer-events: auto; -webkit-backdrop-filter: blur(8px); }
    .pill.on { display: flex; }
    .dot { width: 8px; height: 8px; border-radius: 50%; }
    button { all: unset; cursor: pointer; font-weight: 600; color: #fff; }
    button:hover { text-decoration: underline; }
  `);
  shadow.adoptedStyleSheets = [sheet];
  const pill = (textTag) => {
    const element = document.createElement('div');
    element.className = 'pill';
    const dot = document.createElement('span');
    dot.className = 'dot';
    const text = document.createElement(textTag);
    element.append(dot, text);
    shadow.append(element);
    return { element, dot, text };
  };
  const notice = pill('span');
  const undo = document.createElement('button');
  undo.textContent = 'Undo';
  notice.element.append(undo);
  const offer = pill('button');

  let undoSegments = [];
  // The player pauses on click and goes fullscreen on double-click; clicks here are ours.
  for (const type of ['click', 'dblclick', 'mousedown', 'pointerdown']) host.addEventListener(type, (event) => event.stopPropagation());

  undo.addEventListener('click', () => {
    undoSegments.forEach((segment) => unskipped.add(segment.id));
    if (video && undoSegments.length) video.currentTime = undoSegments[0].start;
    hideNotice();
  });

  let offered = null;
  offer.text.addEventListener('click', () => {
    if (video && offered) video.currentTime = offered.end;
  });

  const mount = () => {
    const player = playerOf(video);
    if (player && host.parentNode !== player) player.append(host);
  };

  const hideNotice = () => {
    clearTimeout(noticeTimer);
    notice.element.classList.remove('on');
    undoSegments = [];
  };

  const showNotice = (skipped) => {
    mount();
    undoSegments = skipped;
    notice.dot.style.background = skipped[0].color;
    notice.text.textContent = skipped.length === 1 ? `Skipped ${skipped[0].label.toLowerCase()}` : `Skipped ${skipped.length} segments`;
    notice.element.classList.add('on');
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(hideNotice, NOTICE_SECONDS * 1000);
  };

  const showOffer = (segment) => {
    offered = segment;
    offer.element.classList.toggle('on', segment !== null);
    if (!segment) return;
    mount();
    offer.dot.style.background = segment.color;
    offer.text.textContent = `Skip ${segment.label.toLowerCase()} ›`;
  };

  // Colored marks on the seek bar, like SponsorBlock's.
  const marks = document.createElement('div');
  marks.style.cssText = 'position:absolute;inset:0;pointer-events:none;z-index:40;';
  let marksKey = '';
  const renderMarks = () => {
    const bar = playerOf(video)?.querySelector('.ytp-progress-bar');
    const duration = video?.duration;
    const shown = Number.isFinite(duration) && duration > 0 && !adShowing() ? segments.filter(fits) : [];
    const key = `${videoID}|${duration}|${shown.map((s) => s.id).join()}`;
    if (!bar || !shown.length) { marks.remove(); marksKey = ''; return; }
    if (marks.parentNode === bar && key === marksKey) return;
    marksKey = key;
    marks.replaceChildren(...shown.map((segment) => {
      const mark = document.createElement('div');
      const left = Math.max(0, segment.start / duration) * 100;
      const width = Math.min(1, segment.end / duration) * 100 - left;
      mark.style.cssText = `position:absolute;top:0;bottom:0;left:${left}%;width:${width}%;background:${segment.color};opacity:.85;`;
      return mark;
    }));
    bar.append(marks);
  };

  const update = () => {
    clearTimeout(timer);
    if (!video) return;
    renderMarks();
    if (!segments.length || adShowing()) { showOffer(null); return; }

    const now = video.currentTime;
    const inside = (segment) => segment.start <= now + 0.05 && now < segment.end - 0.2;
    const automatic = segments.find((segment) => segment.action === 'skip' && active(segment) && inside(segment));
    if (automatic && !video.paused) {
      // Back-to-back or overlapping segments are skipped in one jump.
      const skipped = [automatic];
      let end = automatic.end;
      for (const segment of segments) {
        if (segment !== automatic && segment.action === 'skip' && active(segment) && segment.start <= end + 0.05 && segment.end > end) {
          skipped.push(segment);
          end = segment.end;
        }
      }
      video.currentTime = Number.isFinite(video.duration) ? Math.min(end, video.duration) : end;
      showOffer(null);
      showNotice(skipped);
      return;
    }
    showOffer(segments.find((segment) => segment.action === 'button' && active(segment) && inside(segment)) ?? null);

    // timeupdate only fires every 250 ms or so; a timer lands on the next boundary on time.
    if (video.paused || video.playbackRate <= 0) return;
    const next = Math.min(...segments.filter(active).flatMap((segment) => [segment.start, segment.end]).filter((time) => time > now));
    if (Number.isFinite(next)) timer = setTimeout(update, ((next - now) / video.playbackRate) * 1000);
  };

  const refresh = () => {
    const id = idFrom(location.href) ?? idFrom(playerOf(video)?.querySelector('.ytp-title-link')?.href ?? '');
    if (id === videoID) return;
    videoID = id;
    segments = [];
    unskipped.clear();
    hideNotice();
    update();
    if (!id) return;
    const ticket = ++request;
    bridge.postMessage({ action: 'segments', videoID: id }).then((reply) => {
      if (ticket !== request) return;
      segments = (reply?.segments ?? []).sort((a, b) => a.start - b.start);
      update();
    }, () => {});
  };

  // Media events do not bubble; listening while they travel down to the video catches every
  // player YouTube creates, including the one it reuses from video to video.
  const onMedia = (event) => {
    if (!isPlayerVideo(event.target)) return;
    video = event.target;
    if (event.type === 'loadedmetadata' || event.type === 'durationchange') refresh();
    update();
  };
  for (const type of ['loadedmetadata', 'durationchange', 'play', 'playing', 'pause', 'seeked', 'ratechange', 'timeupdate']) {
    document.addEventListener(type, onMedia, true);
  }
  // YouTube moves between videos without loading a new document.
  window.addEventListener('yt-navigate-finish', () => { refresh(); update(); }, true);
  window.addEventListener('popstate', () => { refresh(); update(); });
})();
