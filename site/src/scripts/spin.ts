// Easter egg: the hero mark is a flywheel. Each click is a push that adds to
// the speed it already has, so a few quick clicks build real momentum; left
// alone it slows under friction and settles exactly upright. It glows with
// its speed, in the page's own glow vocabulary.
//
// Physics, not a canned animation: the old version played the same four
// turns whatever you did and stopped by snapping. Here friction decays the
// speed exponentially, and near the end the wheel is braked evenly onto a
// whole turn it would have coasted past anyway -- a brake never harder than
// the friction it takes over from, so the handover is invisible.
//
// Deliberately unadvertised: no pointer cursor, no focus ring, not in the
// accessibility tree. The mark is decorative and this adds nothing to read.
// Nothing here runs under prefers-reduced-motion: a logo spinning is the
// exact thing that setting is for.

const FLICK = 900; // deg/s each click adds
const FRICTION = 0.55; // per second: v *= e^(-FRICTION * dt)
const LAND = 360; // deg/s: below one turn a second, it is braked onto a whole turn
const MAX_SPEED = 4000; // deg/s: fast enough to blur, short of strobing a 145-segment arc
const GLOW_AT = 1400; // deg/s that reads as full glow
// The park: it arrives upright still moving at ARRIVE, overshoots, and a
// lightly damped spring rocks it back. ~4 degrees past, ~1 back, done in 0.8s.
const ARRIVE = 80; // deg/s left when it reaches upright
const BOUNCE_W = 14; // spring frequency, rad/s
const BOUNCE_Z = 0.32; // damping ratio: under 1, so it rocks
const BOUNCE_T = 0.9; // s

export function initSpin(): void {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  const mark = document.querySelector<HTMLElement>('[data-spin]');
  if (!mark) return;

  let angle = 0; // deg, unbounded: whole turns are kept so it lands forward
  let velocity = 0; // deg/s
  let target: number | null = null; // the whole turn the spring is landing on
  let frame = 0;
  let last = 0;

  function paint(): void {
    mark!.style.transform = `rotate(${angle}deg)`;
    const glow = Math.min(1, Math.abs(velocity) / GLOW_AT);
    mark!.style.setProperty('--spin-glow', glow.toFixed(3));
  }

  // The landing. Below LAND the wheel is braked evenly onto a whole turn
  // it would have coasted past anyway: the brake needed is never harder than
  // the friction it takes over from, so the handover is invisible and it
  // comes to rest exactly upright, still moving forward. (A spring from a
  // crawl, the first try, yanked it up to most of a turn in a fraction of a
  // second.) A wheel let go with no speed at all eases to the nearest turn.
  let decel = 0; // deg/s^2 while braking onto target
  let arrive = 0; // deg/s it keeps for the bounce
  let bounce: { at: number; dir: number; v0: number; t0: number } | null = null;
  let ease: { from: number; to: number; t0: number } | null = null;

  function land(): void {
    const speed = Math.abs(velocity);
    if (speed < 5) {
      const to = Math.round(angle / 360) * 360;
      ease = { from: angle, to, t0: performance.now() };
      velocity = 0;
      return;
    }
    const dir = velocity > 0 ? 1 : -1;
    const coast = speed / FRICTION; // how far friction alone would carry it
    const stop = angle + dir * coast;
    target = dir > 0 ? Math.ceil(stop / 360) * 360 : Math.floor(stop / 360) * 360;
    arrive = Math.min(ARRIVE, speed);
    decel = (speed * speed - arrive * arrive) / (2 * Math.abs(target - angle));
  }

  function rest(): void {
    angle = 0;
    velocity = 0;
    target = null;
    ease = null;
    bounce = null;
    paint();
    mark!.style.transform = '';
    frame = 0;
  }

  function tick(now: number): void {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;

    if (bounce) {
      // an underdamped spring released at upright with the arrival speed
      const t = (now - bounce.t0) / 1000;
      const wd = BOUNCE_W * Math.sqrt(1 - BOUNCE_Z * BOUNCE_Z);
      const x = (bounce.v0 / wd) * Math.exp(-BOUNCE_Z * BOUNCE_W * t) * Math.sin(wd * t);
      angle = bounce.at + (bounce.dir * x * 180) / Math.PI;
      velocity = 0;
      paint();
      if (t >= BOUNCE_T) return rest();
      frame = requestAnimationFrame(tick);
      return;
    }

    if (ease) {
      const t = Math.min(1, (now - ease.t0) / 600);
      const k = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
      angle = ease.from + (ease.to - ease.from) * k;
      paint();
      if (t >= 1) return rest();
      frame = requestAnimationFrame(tick);
      return;
    }

    if (target === null) {
      velocity *= Math.exp(-FRICTION * dt);
      if (Math.abs(velocity) < LAND) land();
      if (ease) {
        frame = requestAnimationFrame(tick);
        return;
      }
    }
    if (target !== null) {
      const dir = target > angle ? 1 : -1;
      const speed = Math.max(arrive, Math.abs(velocity) - decel * dt);
      velocity = dir * speed;
      angle += velocity * dt;
      if (dir > 0 ? angle >= target : angle <= target) {
        // upright, still moving: the arrival speed becomes the bounce
        bounce = { at: target, dir, v0: (arrive * Math.PI) / 180, t0: now };
        target = null;
        angle = bounce.at;
        paint();
        frame = requestAnimationFrame(tick);
        return;
      }
      paint();
      frame = requestAnimationFrame(tick);
      return;
    }
    angle += velocity * dt;
    paint();
    frame = requestAnimationFrame(tick);
  }

  function run(): void {
    if (frame) return;
    last = performance.now();
    frame = requestAnimationFrame(tick);
  }

  // Each click is a push: it adds to whatever speed the wheel already has,
  // in the direction it is already turning, so clicks stack into momentum.
  mark.addEventListener('click', () => {
    const dir = velocity < 0 ? -1 : 1;
    velocity = Math.max(-MAX_SPEED, Math.min(MAX_SPEED, velocity + dir * FLICK));
    target = null;
    ease = null;
    bounce = null;
    run();
  });
}
