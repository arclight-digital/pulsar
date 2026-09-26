// The wallpaper, chosen apart from the theme. A visitor can wear one theme's
// colours over another theme's wallpaper -- Nord over Pulsar's Silk, say.
// Site-only; the OS pairs each theme with its own wallpapers.
//
//   "pulsar"  the live shader, in whichever look (Silk/Leak/Satin/Holo)
//   <slug>    that theme's rendered wallpaper, as a still over the canvas
//
// Picking a theme SUGGESTS its wallpaper until the visitor picks one
// themselves -- a wallpaper in the picker, or a look -- after which themes
// leave it alone. An explicit choice is remembered per visitor like the
// theme; a suggestion is not. A single-mode theme's wallpaper only shows in
// its own mode: a light still under dark-mode text is unreadable, so the sky
// stays live instead.
import { mode, type ThemeDetail } from './themes';

const KEY = 'pulsar-site-wall';
const remember = (v: string | null) => {
  try {
    if (v === null) localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, v);
  } catch {
    /* not remembered */
  }
};
const recall = () => {
  try {
    return localStorage.getItem(KEY);
  } catch {
    return null;
  }
};

export function initWallpaper(): void {
  const layer = document.querySelector<HTMLElement>('[data-wallstill-layer]');
  const choices = () => [...document.querySelectorAll<HTMLElement>('[data-wall]')];
  let value = 'pulsar';
  let chosen = false;

  const apply = (next: string) => {
    value = next;
    for (const b of choices()) {
      const on = b.dataset.wall === next;
      // the live looks are pressed by look (theme.ts); here they only learn
      // whether the live sky is the wallpaper at all
      if (b.hasAttribute('data-look')) b.toggleAttribute('data-live-on', next === 'pulsar');
      else b.setAttribute('aria-pressed', String(on));
    }
    if (!layer) return;
    const b = choices().find((x) => x.dataset.wall === next && !x.hasAttribute('data-look'));
    const src = b && (mode() === 'light' ? b.dataset.light : b.dataset.dark);
    if (next === 'pulsar' || !src) {
      layer.removeAttribute('data-on');
      return;
    }
    let img = layer.querySelector('img');
    if (!img) {
      img = document.createElement('img');
      img.alt = '';
      img.decoding = 'async';
      layer.append(img);
    }
    if (img.getAttribute('src') !== src) img.src = src;
    layer.setAttribute('data-on', '');
  };

  document.addEventListener('click', (e) => {
    const b = (e.target as HTMLElement).closest<HTMLElement>('[data-wall], [data-look]');
    if (!b) return;
    chosen = true;
    const next = b.dataset.wall ?? 'pulsar';
    remember(next);
    apply(next);
  });

  document.addEventListener('pulsar:theme', (e) => {
    if (chosen) return;
    const slug = (e as CustomEvent<ThemeDetail>).detail.slug;
    apply(choices().some((b) => b.dataset.wall === slug) ? slug : 'pulsar');
  });

  document.addEventListener('pulsar:reset', () => {
    chosen = false;
    remember(null);
    apply('pulsar');
  });

  // light/dark changes which render of the chosen wallpaper is right
  new MutationObserver(() => apply(value)).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });

  const stored = recall();
  if (stored) {
    chosen = true;
    apply(stored);
  } else {
    apply('pulsar');
  }
}
