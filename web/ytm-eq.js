/* YouTube Music EQ: a 10-band peaking EQ with auto headroom and a limiter, run inside the
   page with Web Audio. Same bands, Q and headroom math as the Mac EQMenuBar app.
   Run it once to open the panel; running it again re-shows a hidden panel.
   YouTube Music enforces Trusted Types, so the panel is built with createElement and
   textContent only, never innerHTML. */
(() => {
  if (window.__ytmEQ) {
    window.__ytmEQ.panel.style.display = 'block';
    return;
  }

  const CENTERS = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  const LABELS = ['31', '62', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];
  const Q = 1.41;
  const MAX_GAIN = 12;
  const SMOOTHING_SECONDS = 0.015;
  const STORAGE_KEY = 'ytmEQ.gains';

  const eq = {
    ctx: null,
    input: null,
    filters: [],
    headroom: null,
    analyser: null,
    hooked: new WeakSet(),
    bypass: false,
    gains: loadGains(),
    panel: null,
  };
  window.__ytmEQ = eq;

  function loadGains() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
      if (Array.isArray(saved) && saved.length === CENTERS.length) return saved.map(Number);
    } catch (e) {}
    return CENTERS.map(() => 0);
  }

  function saveGains() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(eq.gains));
    } catch (e) {}
  }

  /* RBJ peaking-filter gain in dB at `freq`; matches Biquad.magnitudeDB in the Mac app and
     the formula Web Audio's BiquadFilterNode uses for type "peaking". */
  function peakingDB(center, gainDB, freq, rate) {
    const amplitude = Math.pow(10, gainDB / 40);
    const w0 = (2 * Math.PI * center) / rate;
    const alpha = Math.sin(w0) / (2 * Q);
    const cosW0 = Math.cos(w0);
    const a0 = 1 + alpha / amplitude;
    const b0 = (1 + alpha * amplitude) / a0;
    const b1 = (-2 * cosW0) / a0;
    const b2 = (1 - alpha * amplitude) / a0;
    const a1 = (-2 * cosW0) / a0;
    const a2 = (1 - alpha / amplitude) / a0;
    const w = (2 * Math.PI * freq) / rate;
    const numRe = b0 + b1 * Math.cos(w) + b2 * Math.cos(2 * w);
    const numIm = -(b1 * Math.sin(w) + b2 * Math.sin(2 * w));
    const denRe = 1 + a1 * Math.cos(w) + a2 * Math.cos(2 * w);
    const denIm = -(a1 * Math.sin(w) + a2 * Math.sin(2 * w));
    return 10 * Math.log10((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm));
  }

  /* Peak of the summed curve; overlapping boosts add up, so this can exceed the largest fader. */
  function headroomDB(gains, rate) {
    const probes = [];
    for (let step = 0; step <= 200; step++) probes.push(20 * Math.pow(1000, step / 200));
    let peak = 0;
    for (const freq of probes.concat(CENTERS)) {
      let sum = 0;
      CENTERS.forEach((center, band) => {
        sum += peakingDB(center, gains[band], freq, rate);
      });
      peak = Math.max(peak, sum);
    }
    return peak;
  }

  function activeGains() {
    return eq.bypass ? CENTERS.map(() => 0) : eq.gains;
  }

  function applyGains() {
    saveGains();
    if (!eq.ctx) return;
    const gains = activeGains();
    const now = eq.ctx.currentTime;
    eq.filters.forEach((filter, band) => filter.gain.setTargetAtTime(gains[band], now, SMOOTHING_SECONDS));
    const cut = headroomDB(gains, eq.ctx.sampleRate);
    eq.headroom.gain.setTargetAtTime(Math.pow(10, -cut / 20), now, SMOOTHING_SECONDS);
  }

  /* media element -> 10 peaking filters -> headroom gain -> limiter -> analyser -> speakers */
  function buildChain() {
    const Context = window.AudioContext || window.webkitAudioContext;
    eq.ctx = new Context();
    eq.filters = CENTERS.map((center) => {
      const filter = eq.ctx.createBiquadFilter();
      filter.type = 'peaking';
      filter.frequency.value = center;
      filter.Q.value = Q;
      filter.gain.value = 0;
      return filter;
    });
    eq.headroom = eq.ctx.createGain();

    const limiter = eq.ctx.createDynamicsCompressor();
    limiter.threshold.value = -1.5;
    limiter.knee.value = 0;
    limiter.ratio.value = 20;
    limiter.attack.value = 0.001;
    limiter.release.value = 0.08;

    eq.analyser = eq.ctx.createAnalyser();
    eq.analyser.fftSize = 2048;

    eq.filters.reduce((previous, filter) => {
      previous.connect(filter);
      return filter;
    });
    eq.filters[eq.filters.length - 1].connect(eq.headroom);
    eq.headroom.connect(limiter);
    limiter.connect(eq.analyser);
    eq.analyser.connect(eq.ctx.destination);
    eq.input = eq.filters[0];
  }

  /* YouTube Music usually reuses one <video>, but hook any new media element it adds. */
  function hookMedia() {
    document.querySelectorAll('video, audio').forEach((media) => {
      if (eq.hooked.has(media)) return;
      try {
        eq.ctx.createMediaElementSource(media).connect(eq.input);
        eq.hooked.add(media);
      } catch (error) {
        statusLine.textContent = 'Could not hook the player: ' + error.message;
      }
    });
  }

  function node(tag, styles, text) {
    const element = document.createElement(tag);
    Object.assign(element.style, styles || {});
    if (text != null) element.textContent = text;
    return element;
  }

  function button(label) {
    return node(
      'button',
      {
        background: '#2f6fed',
        color: '#fff',
        border: 'none',
        borderRadius: '8px',
        padding: '6px 10px',
        font: 'inherit',
      },
      label
    );
  }

  function formatGain(value) {
    return (value > 0 ? '+' : '') + value.toFixed(1).replace(/\.0$/, '');
  }

  const panel = node('div', {
    position: 'fixed',
    left: '8px',
    right: '8px',
    bottom: '90px',
    maxWidth: '480px',
    margin: '0 auto',
    zIndex: '2147483647',
    background: 'rgba(22, 22, 26, 0.96)',
    color: '#fff',
    font: '12px -apple-system, system-ui, sans-serif',
    borderRadius: '12px',
    padding: '10px',
    boxShadow: '0 6px 24px rgba(0, 0, 0, 0.5)',
  });
  eq.panel = panel;

  const controls = node('div', { display: 'flex', gap: '6px', alignItems: 'center', flexWrap: 'wrap' });
  const startButton = button('Start EQ');
  const bypassButton = button('Bypass');
  const resetButton = button('Reset');
  const hideButton = button('Hide');
  controls.append(startButton, bypassButton, resetButton, hideButton);

  const statusLine = node('div', { margin: '8px 0', opacity: '0.85' }, 'Tap Start EQ, then play a song.');

  const bands = node('div', { display: 'flex', justifyContent: 'space-between' });
  const sliders = CENTERS.map((center, band) => {
    const column = node('div', { display: 'flex', flexDirection: 'column', alignItems: 'center', width: '9%' });
    const value = node('div', { fontVariantNumeric: 'tabular-nums' }, formatGain(eq.gains[band]));
    const input = document.createElement('input');
    input.type = 'range';
    input.min = String(-MAX_GAIN);
    input.max = String(MAX_GAIN);
    input.step = '0.5';
    input.value = String(eq.gains[band]);
    Object.assign(input.style, {
      writingMode: 'vertical-lr',
      direction: 'rtl',
      height: '120px',
      width: '28px',
      margin: '6px 0',
    });
    input.addEventListener('input', () => {
      eq.gains[band] = Number(input.value);
      value.textContent = formatGain(eq.gains[band]);
      applyGains();
    });
    column.append(value, input, node('div', {}, LABELS[band]));
    bands.append(column);
    return { input, value };
  });

  panel.append(controls, statusLine, bands);
  document.body.append(panel);

  startButton.addEventListener('click', async () => {
    if (!eq.ctx) buildChain();
    await eq.ctx.resume();
    hookMedia();
    applyGains();
    setInterval(hookMedia, 2000);
    startButton.textContent = 'EQ running';
    startButton.disabled = true;
    startButton.style.background = '#2a7a3b';
  });

  bypassButton.addEventListener('click', () => {
    eq.bypass = !eq.bypass;
    bypassButton.textContent = eq.bypass ? 'Bypassed' : 'Bypass';
    bypassButton.style.background = eq.bypass ? '#8a5a00' : '#2f6fed';
    applyGains();
  });

  resetButton.addEventListener('click', () => {
    eq.gains = CENTERS.map(() => 0);
    sliders.forEach(({ input, value }) => {
      input.value = '0';
      value.textContent = '0';
    });
    applyGains();
  });

  hideButton.addEventListener('click', () => {
    panel.style.display = 'none';
  });

  /* Signal check: if a song is playing but the EQ output is silent, iOS WebKit is refusing
     to let the page process YouTube's audio, and this approach won't work. */
  setInterval(() => {
    if (!eq.analyser) return;
    const samples = new Float32Array(eq.analyser.fftSize);
    eq.analyser.getFloatTimeDomainData(samples);
    let peak = 0;
    for (const sample of samples) peak = Math.max(peak, Math.abs(sample));
    const playing = Array.from(document.querySelectorAll('video, audio')).some((media) => !media.paused);
    const signal = !playing ? 'Paused' : peak > 0.0001 ? 'Signal ✓ — EQ is working' : 'Playing but silent ✗';
    const cut = headroomDB(activeGains(), eq.ctx.sampleRate);
    statusLine.textContent = signal + (cut > 0.05 ? ' · headroom −' + cut.toFixed(1) + ' dB' : '');
  }, 300);
})();
