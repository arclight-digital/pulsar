// The hero background: assets/shaders/pulsar.frag -- the SAME shader that
// renders the OS wallpapers -- running live in WebGL1.
//
// The source is compiled into this bundle from the repo's assets/ rather than
// fetched at runtime. It is one file with one meaning: the page and the OS
// cannot show different backgrounds, and the hero no longer waits on a second
// request (or has to survive one failing) before it can draw.
//
// Falls back to the page's CSS ground -- the CI-rendered silk still -- when
// WebGL is missing. prefers-reduced-motion gets still frames that redraw only
// when a control is used.
import fragmentSource from '../../../assets/shaders/pulsar.frag?raw';
import { currentLook, effectiveTheme, handleLookSwitch, onStateChange } from './theme';
import { storedTheme } from './sitetheme';
import { THEMES, type Variant } from '../data/themes';

// ---- the picked theme's palette -------------------------------------------
// The sky wears the theme the visitor picked: its deep/bg ground, and its
// accent plus two supporting hues (the shader mixes them in OKLab). Pulsar
// itself sends nothing -- u_palette_on stays 0 and the brand constants in the
// shader draw exactly the brand sky. Eight colours, no extra noise.
type RGB = [number, number, number];
type Palette = { hi: RGB; mid: RGB; deep: RGB; alt: RGB; ga: RGB; gb: RGB; da: RGB; db: RGB };
const hex = (h: string): RGB => {
  const n = parseInt(h.slice(1), 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
};
const mixc = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const BLACK: RGB = [0, 0, 0];
// the brand values the shader hard-codes, so a fade to or from Pulsar lands
// exactly on them
const BRAND: Palette = {
  hi: [0.243, 0.796, 1.0], mid: [0.561, 0.659, 1.0], deep: [0.294, 0.247, 0.831], alt: [0.98, 0.52, 0.76],
  ga: [0.005, 0.006, 0.016], gb: [0.016, 0.019, 0.048], da: [0.906, 0.916, 0.958], db: [0.822, 0.842, 0.922],
};
const KEYS = ['hi', 'mid', 'deep', 'alt', 'ga', 'gb', 'da', 'db'] as const;

// swatch order (data/themes.json): bg, raised, accent, red, yellow, green,
// cyan, blue, magenta, fg
function paletteFor(slug: string | null, mode: 'dark' | 'light'): Palette | null {
  const t = slug ? THEMES.find((x) => x.slug === slug) : undefined;
  if (!t || t.slug === 'pulsar') return null;
  const lightsFrom: Variant | undefined = t.variants[mode] ?? t.variants.dark ?? t.variants.light;
  const dark: Variant | undefined = t.variants.dark ?? t.variants.light;
  const light: Variant | undefined = t.variants.light ?? t.variants.dark;
  if (!lightsFrom || !dark || !light) return null;
  const sw = lightsFrom.swatch.map(hex);
  const deepGround = hex(dark.deep);
  return {
    hi: hex(lightsFrom.accent),
    mid: sw[7],
    deep: mode === 'dark' ? mixc(sw[8], hex(lightsFrom.bg), 0.35) : sw[8],
    alt: sw[3],
    ga: mixc(deepGround, BLACK, 0.62),
    gb: mixc(deepGround, BLACK, 0.3),
    da: hex(light.bg),
    db: mixc(hex(light.bg), hex(light.deep), 0.5),
  };
}

function compile(gl: WebGLRenderingContext, type: GLenum, source: string): WebGLShader {
  const shader = gl.createShader(type);
  if (!shader) throw new Error('could not create shader');
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader) ?? 'shader compile failed');
  }
  return shader;
}

export function initSky(): void {
  const canvas = document.querySelector<HTMLCanvasElement>('#sky');
  const fade = document.querySelector<HTMLCanvasElement>('#skyfade');
  if (!canvas || !fade) return;

  // preserveDrawingBuffer so a look switch can snapshot the outgoing frame
  const gl = canvas.getContext('webgl', { antialias: false, preserveDrawingBuffer: true });
  if (!gl) return; // the CSS ground is the fallback; the deck still themes the page
  const fadeContext = fade.getContext('2d');

  try {
    const program = gl.createProgram();
    if (!program) throw new Error('could not create program');
    gl.attachShader(
      program,
      compile(
        gl,
        gl.VERTEX_SHADER,
        'attribute vec2 p; void main(){ gl_Position = vec4(p,0.,1.); }',
      ),
    );
    gl.attachShader(
      program,
      compile(gl, gl.FRAGMENT_SHADER, `precision highp float;\n${fragmentSource}`),
    );
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program) ?? 'program link failed');
    }
    gl.useProgram(program);

    // one full-screen triangle; nothing here needs a quad
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, 'p');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);

    const uResolution = gl.getUniformLocation(program, 'u_resolution');
    const uTime = gl.getUniformLocation(program, 'u_time');
    const uTheme = gl.getUniformLocation(program, 'u_theme');
    const uLook = gl.getUniformLocation(program, 'u_look');
    // The live sky runs the luminescence at a hint of its wallpaper strength:
    // at full strength silk's filaments made the hero text hard to read.
    const uLive = gl.getUniformLocation(program, 'u_live');
    const uPalOn = gl.getUniformLocation(program, 'u_palette_on');
    const uPal = Object.fromEntries(KEYS.map((k) => [k, gl.getUniformLocation(program, `u_p_${k}`)]));

    // palette state: what is shown eases toward the target like the
    // light/dark crossfade; a stored theme is shown from the first frame
    let themeSlug: string | null = storedTheme();
    const paletteTarget = (): Palette | null => paletteFor(themeSlug, effectiveTheme());
    let palOn = paletteTarget() !== null;
    const shown: Palette = structuredClone(paletteTarget() ?? BRAND);
    document.addEventListener('pulsar:theme', (e) => {
      themeSlug = (e as CustomEvent<{ slug: string }>).detail.slug;
    });
    document.addEventListener('pulsar:reset', () => {
      themeSlug = null;
    });
    // step the shown palette toward the target: 1 snaps (reduced motion)
    const stepPalette = (k: number): void => {
      const t = paletteTarget();
      if (t) palOn = true;
      const goal = t ?? BRAND;
      let still = true;
      for (const key of KEYS) {
        const a = shown[key];
        const b = goal[key];
        for (let i = 0; i < 3; i++) {
          a[i] += (b[i] - a[i]) * k;
          if (Math.abs(b[i] - a[i]) > 0.001) still = false;
          else a[i] = b[i];
        }
      }
      // back on Pulsar and arrived: hand the sky back to the brand constants
      if (!t && still) palOn = false;
    };

    const resize = (): void => {
      const dpr = Math.min(devicePixelRatio || 1, 2);
      canvas.width = Math.round(canvas.clientWidth * dpr);
      canvas.height = Math.round(canvas.clientHeight * dpr);
      gl.viewport(0, 0, canvas.width, canvas.height);
    };
    resize();
    addEventListener('resize', resize);

    // The shader is provably running, so NOW the backdrop controls may exist.
    // A visitor without a GL context must never see buttons that do nothing.
    const lookSeg = document.getElementById('lookSeg');
    if (lookSeg) lookSeg.hidden = false;

    // shown values ease toward their targets so deck switches crossfade
    let themeShown = effectiveTheme() === 'light' ? 1 : 0;
    let lookShown: number = currentLook();

    const draw = (seconds: number): void => {
      gl.uniform2f(uResolution, canvas.width, canvas.height);
      gl.uniform1f(uTime, seconds);
      gl.uniform1f(uTheme, themeShown);
      gl.uniform1f(uLook, lookShown);
      gl.uniform1f(uLive, 1);
      gl.uniform1f(uPalOn, palOn ? 1 : 0);
      for (const key of KEYS) gl.uniform3fv(uPal[key], shown[key]);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };

    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      // No animation: snap the uniforms and redraw only when something
      // changes. onStateChange covers both controls -- it runs after every
      // reflect -- so there is no crossfade to register.
      const snap = (): void => {
        themeShown = effectiveTheme() === 'light' ? 1 : 0;
        lookShown = currentLook();
        stepPalette(1);
        draw(0);
      };
      snap();
      onStateChange(snap);
      addEventListener('resize', snap);
      document.addEventListener('pulsar:theme', () => requestAnimationFrame(snap));
      document.addEventListener('pulsar:reset', () => requestAnimationFrame(snap));
      return;
    }

    // Look switches must NOT ease u_look: the shader chain-mixes the looks, so
    // a scalar sweep from holo to silk marches through satin and leak on the
    // way. Instead freeze the outgoing frame on the overlay canvas, snap
    // u_look underneath it, and let the snapshot dissolve.
    handleLookSwitch((next) => {
      if (fadeContext) {
        fade.width = canvas.width;
        fade.height = canvas.height;
        fadeContext.drawImage(canvas, 0, 0);
        fade.style.transition = 'none';
        fade.style.opacity = '1';
        requestAnimationFrame(() => {
          fade.style.transition = 'opacity 0.7s cubic-bezier(0.16, 1, 0.3, 1)';
          fade.style.opacity = '0';
        });
      }
      lookShown = next;
    });

    const loop = (ms: number): void => {
      const target = effectiveTheme() === 'light' ? 1 : 0;
      themeShown += (target - themeShown) * 0.08;
      if (Math.abs(target - themeShown) < 0.002) themeShown = target;
      stepPalette(0.08); // ~700 ms to settle at 60 fps, like the mode fade
      draw(ms / 1000);
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  } catch {
    // A driver that reports a context but cannot compile the shader keeps the
    // CSS ground, exactly like no context at all.
  }
}
