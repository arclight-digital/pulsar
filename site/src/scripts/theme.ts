// The page's theme and the hero's look, as one answer.
//
// Theme is ARC UI's: data-theme="dark" | "light" | "auto" on <html>, owned by
// arc-theme-toggle (which persists it under localStorage "arc-theme") and by
// the pre-paint script in Base.astro. This module does not write the theme
// any more; it watches the attribute and tells the shader, so the sky can
// never disagree with the page tokens.
//
// The look -- which of the four shipped wallpapers the hero renders -- is
// still ours. A stored choice beats the default; the default is silk.
import { store } from './store';

export type Theme = 'dark' | 'light';
export type Look = 0 | 1 | 2 | 3;

const LOOK_KEY = 'pulsar-look';

const root = document.documentElement;
const sysLight = matchMedia('(prefers-color-scheme: light)');

let look: Look = readLook();

function readLook(): Look {
  const stored = Number(store.get(LOOK_KEY));
  return stored === 1 || stored === 2 || stored === 3 ? stored : 0;
}

/** What the page is actually wearing: the explicit choice, or the system's. */
export function effectiveTheme(): Theme {
  const set = root.dataset.theme;
  if (set === 'light' || set === 'dark') return set;
  return sysLight.matches ? 'light' : 'dark';
}

export function currentLook(): Look {
  return look;
}

// sky.ts registers here. A look switch cannot ease u_look -- the shader
// chain-mixes the looks, so a scalar sweep from holo to silk marches through
// satin and leak on the way -- so the shader is handed the change to crossfade
// itself rather than being left to interpolate.
type LookSwitch = (next: Look) => void;
let onLookSwitch: LookSwitch | null = null;
export function handleLookSwitch(fn: LookSwitch): void {
  onLookSwitch = fn;
}

// Fires after any change to theme or look, and after the initial read. The
// reduced-motion shader path uses it as its only redraw trigger.
const listeners: Array<() => void> = [];
export function onStateChange(fn: () => void): void {
  listeners.push(fn);
}

function reflect(): void {
  const theme = effectiveTheme();

  // Each mark names its own pair, because the slots no longer share a file:
  // the brand is a responsive family, and the 28px bar, 44px footer and hero
  // each take the drawing made for their size.
  //
  // Light theme gets STATIC marks. The brand package has no animated -light
  // cut, and recolouring the dark animation would be exactly the derived
  // light art the package's authored -light files exist to replace. The
  // animated cuts carry their own CSS: an <img> runs animation inside the SVG
  // but exposes nothing to page CSS, and the file's own prefers-reduced-motion
  // rule stops the pulse without JS involvement.
  for (const mark of document.querySelectorAll<HTMLImageElement>('[data-mark]')) {
    // A mark on a .theme-fixed-dark surface (the footer always, the top bar
    // off the home page) sits on dark ground whatever the site theme is, so
    // it keeps the dark cut. Swapping it drew the light-ground mark, with its
    // deep-violet core, on near-black.
    const onLight = theme === 'light' && !mark.closest('.theme-fixed-dark');
    const next = onLight ? mark.dataset.light : mark.dataset.dark;
    // reflect() also runs on every look switch; leave an unchanged mark alone.
    if (next && mark.getAttribute('src') !== next) mark.src = next;
  }

  for (const button of document.querySelectorAll<HTMLElement>('[data-look]')) {
    button.setAttribute('aria-pressed', String(Number(button.dataset.look) === look));
  }

  for (const fn of listeners) fn();
}

export function initTheme(): void {
  reflect();

  for (const button of document.querySelectorAll<HTMLElement>('[data-look]')) {
    button.addEventListener('click', () => {
      const next = Number(button.dataset.look);
      if (next !== 0 && next !== 1 && next !== 2 && next !== 3) return;
      if (next === look) return;
      onLookSwitch?.(next);
      look = next;
      store.set(LOOK_KEY, String(look));
      reflect();
    });
  }

  // arc-theme-toggle writes data-theme; this is how the shader hears about it.
  new MutationObserver(reflect).observe(root, { attributes: true, attributeFilter: ['data-theme'] });
  sysLight.addEventListener('change', reflect);
}
