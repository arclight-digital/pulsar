// Hero background: assets/pulsar.frag (the OS wallpaper shader) live in
// WebGL1, plus the deck controls that drive it. u_theme starts from the
// visitor's color scheme and u_look from Silk; both are overridable from the
// deck and persisted. The theme choice also swaps the page tokens (via
// data-theme on <html>) and the mark (ink cut on light, same as the shipped
// wallpapers). Falls back to the page's CSS ground when WebGL is missing;
// prefers-reduced-motion gets still frames that redraw only on control use.
(() => {
  const root = document.documentElement;
  const marks = document.querySelectorAll('[data-mark]');
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const sysLight = matchMedia('(prefers-color-scheme: light)');

  // ---- state: stored choice beats system, system is the default ----------
  let theme = localStorage.getItem('pulsar-theme');       // 'dark' | 'light' | null
  let look = Number(localStorage.getItem('pulsar-look') || 0);

  const effectiveTheme = () => theme || (sysLight.matches ? 'light' : 'dark');

  // set by the gl section; lets a look switch snapshot the outgoing frame
  let onLookSwitch = null;

  const reflect = () => {
    const t = effectiveTheme();
    if (theme) root.dataset.theme = theme;
    else delete root.dataset.theme;                        // back to system
    marks.forEach(m => {
      m.src = t === 'light' ? 'assets/pulsar-mark-ink.svg' : 'assets/pulsar-mark.svg';
    });
    document.querySelectorAll('[data-theme-pick]').forEach(b =>
      b.setAttribute('aria-pressed', String(b.dataset.themePick === t)));
    document.querySelectorAll('[data-look]').forEach(b =>
      b.setAttribute('aria-pressed', String(Number(b.dataset.look) === look)));
  };
  reflect();

  document.querySelectorAll('[data-theme-pick]').forEach(b =>
    b.addEventListener('click', () => {
      theme = b.dataset.themePick;
      localStorage.setItem('pulsar-theme', theme);
      reflect();
    }));
  document.querySelectorAll('[data-look]').forEach(b =>
    b.addEventListener('click', () => {
      const next = Number(b.dataset.look);
      if (next === look) return;
      if (onLookSwitch) onLookSwitch(next);
      look = next;
      localStorage.setItem('pulsar-look', String(look));
      reflect();
    }));
  sysLight.addEventListener('change', reflect);

  // ---- copy buttons -------------------------------------------------------
  document.querySelectorAll('[data-copy]').forEach(btn =>
    btn.addEventListener('click', async () => {
      const code = btn.parentElement.querySelector('code');
      try { await navigator.clipboard.writeText(code.textContent.trim()); }
      catch { return; } // clipboard denied: no false "copied" state
      btn.classList.add('did');
      setTimeout(() => btn.classList.remove('did'), 1400);
    }));

  // ---- the shader ---------------------------------------------------------
  const canvas = document.getElementById('sky');
  // preserveDrawingBuffer so a look switch can snapshot the outgoing frame
  const gl = canvas.getContext('webgl', { antialias: false, preserveDrawingBuffer: true });
  if (!gl) return; // CSS ground is the fallback; controls still theme the page
  const fade = document.getElementById('skyfade');
  const fctx = fade.getContext('2d');

  fetch('assets/pulsar.frag')
    .then(r => r.text())
    .then(src => {
      const compile = (type, s) => {
        const sh = gl.createShader(type);
        gl.shaderSource(sh, s);
        gl.compileShader(sh);
        if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS))
          throw new Error(gl.getShaderInfoLog(sh));
        return sh;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl.VERTEX_SHADER,
        'attribute vec2 p; void main(){ gl_Position = vec4(p,0.,1.); }'));
      gl.attachShader(prog, compile(gl.FRAGMENT_SHADER,
        'precision highp float;\n' + src));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS))
        throw new Error(gl.getProgramInfoLog(prog));
      gl.useProgram(prog);

      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(prog, 'p');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

      const uRes = gl.getUniformLocation(prog, 'u_resolution');
      const uTime = gl.getUniformLocation(prog, 'u_time');
      const uTheme = gl.getUniformLocation(prog, 'u_theme');
      const uLook = gl.getUniformLocation(prog, 'u_look');

      const resize = () => {
        const dpr = Math.min(devicePixelRatio || 1, 2);
        canvas.width = Math.round(canvas.clientWidth * dpr);
        canvas.height = Math.round(canvas.clientHeight * dpr);
        gl.viewport(0, 0, canvas.width, canvas.height);
      };
      addEventListener('resize', resize);
      resize();

      // shown values ease toward targets so deck switches crossfade
      let themeShown = effectiveTheme() === 'light' ? 1 : 0;
      let lookShown = look;

      const draw = (t) => {
        gl.uniform2f(uRes, canvas.width, canvas.height);
        gl.uniform1f(uTime, t);
        gl.uniform1f(uTheme, themeShown);
        gl.uniform1f(uLook, lookShown);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      };

      if (still) {
        // no animation: snap uniforms and redraw only when something changes
        const snap = () => {
          themeShown = effectiveTheme() === 'light' ? 1 : 0;
          lookShown = look;
          draw(0);
        };
        snap();
        document.querySelectorAll('.deck button').forEach(b =>
          b.addEventListener('click', snap));
        sysLight.addEventListener('change', snap);
        addEventListener('resize', snap);
        return;
      }

      // Look switches must NOT ease u_look: the shader chain-mixes the looks,
      // so a scalar sweep from holo to silk marches through satin and leak on
      // the way. Instead: freeze the outgoing frame on the overlay canvas,
      // snap u_look underneath it, and let the snapshot dissolve.
      onLookSwitch = (next) => {
        fade.width = canvas.width;
        fade.height = canvas.height;
        fctx.drawImage(canvas, 0, 0);
        fade.style.transition = 'none';
        fade.style.opacity = '1';
        requestAnimationFrame(() => {
          fade.style.transition = 'opacity 0.7s cubic-bezier(0.16, 1, 0.3, 1)';
          fade.style.opacity = '0';
        });
        lookShown = next;
      };

      const loop = (ms) => {
        const tTarget = effectiveTheme() === 'light' ? 1 : 0;
        themeShown += (tTarget - themeShown) * 0.08;
        if (Math.abs(tTarget - themeShown) < 0.002) themeShown = tTarget;
        draw(ms / 1000);
        requestAnimationFrame(loop);
      };
      requestAnimationFrame(loop);
    })
    .catch(() => { /* keep the CSS ground */ });
})();
