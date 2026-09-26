// Wearing a theme across the whole site. The stylesheet comes from
// data/sitetheme.ts (tokens only, contrast-fitted); this module puts it on
// the page, remembers it, and handles the single-mode themes.
//
// Remembered per visitor in localStorage -- the slug, the finished CSS and a
// forced mode -- so the inline script in Base.astro can apply it before first
// paint on the next page, with no flash of Pulsar. Every storage call is
// wrapped: private windows and blocked storage just mean it isn't remembered.
//
// Single-mode themes (Dracula, Phosphor and Amber dark; Alucard light) set the
// page's mode while they are worn, and the mode the visitor had comes back
// when they switch to a two-variant theme or reset.
import { cssFor, onlyMode } from '../data/sitetheme';
import { THEMES } from '../data/themes';

const K = {
  slug: 'pulsar-site-theme',
  css: 'pulsar-site-theme-css',
  mode: 'pulsar-site-theme-mode',
  before: 'pulsar-site-theme-mode-before',
};
const get = (k: string) => {
  try {
    return localStorage.getItem(k);
  } catch {
    return null;
  }
};
const set = (k: string, v: string | null) => {
  try {
    if (v === null) localStorage.removeItem(k);
    else localStorage.setItem(k, v);
  } catch {
    /* not remembered; still applied */
  }
};

const STYLE_ID = 'pulsar-site-theme';
const root = document.documentElement;

export const storedTheme = () => get(K.slug);

export function applySiteTheme(slug: string): void {
  const t = THEMES.find((x) => x.slug === slug);
  let style = document.getElementById(STYLE_ID) as HTMLStyleElement | null;

  if (!t || slug === 'pulsar') {
    // Pulsar is the site's own palette: take everything off.
    style?.remove();
    restoreMode();
    for (const k of [K.slug, K.css, K.mode]) set(k, null);
    return;
  }

  const css = cssFor(t);
  if (!style) {
    style = document.createElement('style');
    style.id = STYLE_ID;
    document.head.append(style);
  }
  style.textContent = css;

  const only = onlyMode(t);
  if (only) {
    if (get(K.before) === null) set(K.before, root.dataset.theme ?? 'auto');
    if (root.dataset.theme !== only) root.dataset.theme = only;
  } else {
    restoreMode();
  }
  set(K.slug, slug);
  set(K.css, css);
  set(K.mode, only);
}

function restoreMode() {
  const before = get(K.before);
  if (before !== null) {
    if (root.dataset.theme !== before) root.dataset.theme = before;
    set(K.before, null);
  }
}
