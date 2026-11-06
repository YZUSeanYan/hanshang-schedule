(() => {
  'use strict';
  const section = document.getElementById('promo-video');
  if (!section) return;
  const stage = section.querySelector('.promo-stage');
  const button = section.querySelector('.promo-play');
  const status = section.querySelector('[data-video-status]');
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  const saveData = Boolean(navigator.connection && navigator.connection.saveData);
  let frame = null, autoAttempted = false, unloadTimer = 0, inView = false;
  button.hidden = false;
  function unload() {
    if (!frame) return;
    const old = frame;
    frame = null;
    autoAttempted = false;
    old.pause(); old.removeAttribute('src'); old.load(); old.remove();
    stage.classList.remove('is-loaded');
    button.hidden = false;
    button.querySelector('span').textContent = '重新播放';
    status.textContent = '点击重新播放，可在播放器中调节音量。';
  }
  async function play(manual = false) {
    clearTimeout(unloadTimer);
    autoAttempted = true;
    if (!frame) {
      const current = document.createElement('video');
      current.controls = true;
      current.playsInline = true;
      current.preload = 'metadata';
      current.muted = false;
      current.volume = 0.5;
      current.setAttribute('aria-label', '邗上课表 15 秒宣传片');
      current.src = 'assets/promo-15s-v2.mp4';
      frame = current;
      current.addEventListener('loadeddata', () => {
        if (frame === current) stage.classList.add('is-loaded');
      });
      current.addEventListener('playing', () => {
        if (frame !== current) return;
        button.hidden = !current.muted;
        button.querySelector('span').textContent = current.muted ? '开启声音' : '播放宣传片';
        status.textContent = current.muted ? '正在自动播放，点击开启声音。' : '默认音量 50%，可在播放器中调节。';
      });
      current.addEventListener('volumechange', () => {
        if (frame !== current || current.paused) return;
        button.hidden = !current.muted;
        button.querySelector('span').textContent = '开启声音';
        status.textContent = current.muted ? '正在静音播放，点击开启声音。' : '可在播放器中调节音量。';
      });
      current.addEventListener('error', () => {
        if (frame !== current) return;
        unload(); status.textContent = '视频暂时无法加载，请点击重试。';
      });
      stage.appendChild(current);
    }
    const current = frame;
    if (manual) current.muted = false;
    button.hidden = true;
    status.textContent = '正在加载视频…';
    try { await current.play(); }
    catch (error) {
      if (frame !== current) return;
      if (!manual && error.name === 'NotAllowedError') {
        current.muted = true;
        try { await current.play(); return; }
        catch (_) { if (frame !== current) return; }
      }
      button.hidden = false;
      button.querySelector('span').textContent = '点击有声播放';
      status.textContent = error.name === 'NotAllowedError'
        ? '点击播放，默认音量 50%。'
        : '暂时无法播放，请点击重试。';
    }
  }
  button.addEventListener('click', () => play(true));
  if ('IntersectionObserver' in window) {
    section.classList.add('promo-reveal-ready');
    const reveal = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) {
        section.classList.add('is-visible'); reveal.disconnect();
      }
    }, {threshold: .08});
    reveal.observe(section);
    const visibility = new IntersectionObserver(entries => {
      const entry = entries[0];
      inView = entry.isIntersecting && entry.intersectionRatio >= .2;
      clearTimeout(unloadTimer);
      if (inView && !document.hidden && !autoAttempted && !reduced.matches && !saveData) play();
      if (!entry.isIntersecting && frame) unloadTimer = window.setTimeout(unload, 1800);
    }, {threshold: [0, .2]});
    visibility.observe(stage);
  } else section.classList.add('is-visible');
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) unload();
    else if (inView && !autoAttempted && !reduced.matches && !saveData) play();
  });
  if (saveData || reduced.matches) status.textContent = '点击播放宣传片，可在播放器中调节音量。';
})();
