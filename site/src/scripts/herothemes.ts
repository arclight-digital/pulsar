// Hero option (a): the sky steps through the themes. Each theme's wallpaper
// still -- the same shader, rendered in that palette -- fades in over the live
// canvas; Pulsar's own is the live canvas itself, so stepping back to it
// simply fades every still out.
//
// It advances on its own, slowly, until someone touches the deck; from then
// on it is theirs. Stepping by hand also picks the theme for the rest of the
// page (the pulsar:theme event); the idle drift does not, because recolouring
// a page nobody asked to recolour is noise. Reduced motion: no drift at all,
// and the stills swap without a fade (the stylesheet drops the transition).
import { detailOf, pick } from './themes';

const DRIFT_MS = 7000;

export function initHeroThemes(): void {
  const deck = document.querySelector<HTMLElement>('[data-tdeck]');
  if (!deck) return;
  const tiles = [...document.querySelectorAll<HTMLElement>('#themes [data-theme-tile]')];
  if (!tiles.length) return;
  const name = deck.querySelector('[data-tdeck-name]');
  const cmd = deck.querySelector('[data-tdeck-cmd]');
  let index = 0;
  let timer = 0;

  const show = (i: number) => {
    index = (i + tiles.length) % tiles.length;
    const d = detailOf(tiles[index]);
    document.querySelectorAll<HTMLElement>('[data-still]').forEach((s) => {
      const on = s.dataset.still === d.slug;
      if (on) s.querySelectorAll<HTMLImageElement>('img[data-src]').forEach((img) => (img.src = img.dataset.src!));
      s.toggleAttribute('data-on', on);
    });
    if (name) name.textContent = d.name;
    if (cmd) cmd.textContent = `pulsar theme set ${d.slug}`;
    return d;
  };

  const stop = () => clearInterval(timer);
  deck.addEventListener('click', (e) => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-tstep]');
    if (!b) return;
    stop();
    pick(show(index + Number(b.dataset.tstep)));
  });
  // A theme picked anywhere else on the page takes the sky with it.
  document.addEventListener('pulsar:theme', (e) => {
    const slug = (e as CustomEvent<{ slug: string }>).detail.slug;
    const i = tiles.findIndex((t) => t.dataset.themeTile === slug);
    if (i >= 0 && i !== index) show(i);
  });

  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  timer = window.setInterval(() => {
    if (!document.hidden) show(index + 1);
  }, DRIFT_MS);
  deck.addEventListener('pointerenter', stop, { once: true });
  deck.addEventListener('focusin', stop, { once: true });
}
