// Easter egg: flick the hero mark and it spins down like a flywheel.
//
// Deliberately unadvertised -- no pointer cursor, no focus ring, not in the
// accessibility tree. The mark is decorative (alt="") and this adds nothing to
// read, so surfacing it as a control would be noise for everyone who did not
// go looking.
//
// Nothing here runs under prefers-reduced-motion. A logo doing four turns is
// the exact thing that setting is for, and a hidden joke is not worth making
// someone dizzy over.

/** Where the mark is pointing right now, mid-spin or at rest. */
function currentAngle(element: HTMLElement): number {
  const { transform } = getComputedStyle(element);
  // `none` at rest; a matrix once the animation has a computed value
  const matrix = transform.match(/^matrix\(([^)]+)\)/);
  if (!matrix?.[1]) return 0;
  const [a, b] = matrix[1].split(',').map(Number);
  if (a === undefined || b === undefined) return 0;
  return (Math.atan2(b, a) * 180) / Math.PI;
}

export function initSpin(): void {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  const mark = document.querySelector<HTMLImageElement>('[data-spin]');
  if (!mark) return;

  mark.addEventListener('click', () => {
    // A click mid-spin re-flicks it. Restarting from zero would snap the mark
    // back to its resting angle first, which looks like a bug rather than a
    // second flick -- so the keyframes start from wherever it has actually
    // got to, and this hands them that angle.
    mark.style.setProperty('--spin-from', `${currentAngle(mark)}deg`);

    // The class goes on once and STAYS ON, including after the spin ends.
    // The mark is a child of .hero-inner, whose stagger sets `animation:
    // settle` on every child; .mark.is-spinning is what overrides it. Take
    // the class off and animation-name flips back to settle, which the
    // browser treats as newly applied and runs again -- the mark fades up
    // from opacity 0 through a 6px blur, half a second after the spin has
    // finished. Leaving the class on costs nothing (a completed animation
    // paints nothing) and is the whole fix.
    mark.classList.add('is-spinning');

    // Restart by clearing the animation for one reflow rather than by
    // toggling the class, so settle is never reintroduced even for an
    // instant. Reading offsetWidth is what forces the browser to flush the
    // removal instead of coalescing both changes into no change at all.
    mark.style.animation = 'none';
    void mark.offsetWidth;
    mark.style.animation = '';
  });
}
