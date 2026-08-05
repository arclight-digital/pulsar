// Hero background: assets/pulsar.frag (the OS wallpaper shader) live in
// WebGL1. u_theme follows the visitor's color scheme, so the hero IS the
// wallpaper they would get. Falls back to the page's CSS ground when WebGL
// is missing; renders a single still frame when the visitor prefers
// reduced motion.
(() => {
  const canvas = document.getElementById('sky');
  const gl = canvas.getContext('webgl', { antialias: false });
  if (!gl) return; // CSS ground is the fallback

  const light = matchMedia('(prefers-color-scheme: light)');
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

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

      const resize = () => {
        const dpr = Math.min(devicePixelRatio || 1, 2);
        canvas.width = Math.round(canvas.clientWidth * dpr);
        canvas.height = Math.round(canvas.clientHeight * dpr);
        gl.viewport(0, 0, canvas.width, canvas.height);
      };
      addEventListener('resize', resize);
      resize();

      const draw = (t) => {
        gl.uniform2f(uRes, canvas.width, canvas.height);
        gl.uniform1f(uTime, t);
        gl.uniform1f(uTheme, light.matches ? 1.0 : 0.0);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      };

      if (still) {
        draw(0);
        light.addEventListener('change', () => draw(0));
        addEventListener('resize', () => draw(0));
        return;
      }
      const loop = (ms) => { draw(ms / 1000); requestAnimationFrame(loop); };
      requestAnimationFrame(loop);
    })
    .catch(() => { /* keep the CSS ground */ });
})();
