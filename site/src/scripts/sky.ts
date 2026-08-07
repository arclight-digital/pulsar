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
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    };

    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      // No animation: snap the uniforms and redraw only when something
      // changes. onStateChange covers both controls -- it runs after every
      // reflect -- so there is no crossfade to register.
      const snap = (): void => {
        themeShown = effectiveTheme() === 'light' ? 1 : 0;
        lookShown = currentLook();
        draw(0);
      };
      snap();
      onStateChange(snap);
      addEventListener('resize', snap);
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
      draw(ms / 1000);
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  } catch {
    // A driver that reports a context but cannot compile the shader keeps the
    // CSS ground, exactly like no context at all.
  }
}
