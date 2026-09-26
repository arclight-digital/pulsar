// The wallpaper picker, independent of the theme picker. A visitor can wear
// one theme's colours over another theme's wallpaper -- Nord over Pulsar's
// Silk, say. Site-only; the OS pairs each theme with its own wallpapers.
//
//   "pulsar"  the live shader, with the looks row (Silk/Leak/Satin/Holo)
//   <slug>    that theme's rendered wallpaper, as a still over the canvas
//
// Picking a theme SUGGESTS its wallpaper, until the visitor picks one
// themselves -- the palette menu or a look button -- after which theme
// changes leave the wallpaper alone for the rest of the visit. Nothing is
// stored: a reload is Pulsar, live, silk.
import { mode, type ThemeDetail } from './themes';

export function initWallpaper(): void {
  const select = document.querySelector<HTMLSelectElement>('[data-wall-palette]');
  const layer = document.querySelector<HTMLElement>('[data-wallstill-layer]');
  const looks = document.querySelector<HTMLElement>('[data-looks]');
  if (!select || !layer) return;
  let chosen = false;

  const apply = (value: string) => {
    select.value = value;
    const opt = select.selectedOptions[0];
    if (value === 'pulsar' || !opt) {
      layer.removeAttribute('data-on');
      if (looks) looks.hidden = false;
      return;
    }
    const src = mode() === 'light' ? opt.dataset.light : opt.dataset.dark;
    if (!src) {
      // this theme has no wallpaper for the page's mode (a single-mode theme
      // on the other mode): keep the live sky, and the choice, until it does
      layer.removeAttribute('data-on');
      if (looks) looks.hidden = false;
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
    // The looks row drives the live shader; with a theme's still on show it
    // would do nothing visible, so it steps aside until "Pulsar, live".
    if (looks) looks.hidden = true;
  };

  select.addEventListener('change', () => {
    chosen = true;
    apply(select.value);
  });
  // A look button is a wallpaper choice too: back to the live sky.
  looks?.addEventListener('click', (e) => {
    if (!(e.target as HTMLElement).closest('[data-look]')) return;
    chosen = true;
    apply('pulsar');
  });

  document.addEventListener('pulsar:theme', (e) => {
    if (chosen) return;
    const slug = (e as CustomEvent<ThemeDetail>).detail.slug;
    const has = [...select.options].some((o) => o.value === slug);
    // Pulsar's own themes suggest the live sky; Holo also suggests the Holo
    // look, which is exactly its shipped wallpaper minus the mark.
    if (slug === 'pulsar-holo') document.querySelector<HTMLElement>('[data-look="3"]')?.click();
    apply(has ? slug : 'pulsar');
    if (slug === 'pulsar-holo') chosen = false; // the click above was ours, not theirs
  });

  // light/dark changes which render of the chosen wallpaper is right
  new MutationObserver(() => apply(select.value)).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });
}
