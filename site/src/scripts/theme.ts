// The deck's state: which theme the page wears and which of the four shipped
// wallpaper looks the hero renders. A stored choice beats the system; the
// system is the default.
//
// This module owns the state and the DOM reflection. sky.ts subscribes to it
// rather than reading storage itself, so there is one answer to "what theme is
// this" and the shader can never disagree with the page tokens.
import { store } from './store';

export type Theme = 'dark' | 'light';
export type Look = 0 | 1 | 2 | 3;

const THEME_KEY = 'pulsar-theme';
const LOOK_KEY = 'pulsar-look';

const root = document.documentElement;
const sysLight = matchMedia('(prefers-color-scheme: light)');

/** An explicit choice, or null to follow the system. */
let chosen: Theme | null = readTheme();
let look: Look = readLook();

function readTheme(): Theme | null {
  const stored = store.get(THEME_KEY);
  return stored === 'dark' || stored === 'light' ? stored : null;
}

function readLook(): Look {
  const stored = Number(store.get(LOOK_KEY));
  return stored === 1 || stored === 2 || stored === 3 ? stored : 0;
}

export function effectiveTheme(): Theme {
  return chosen ?? (sysLight.matches ? 'light' : 'dark');
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

// Fires after any change to either control, and after the initial read. The
// reduced-motion shader path uses it as its only redraw trigger.
const listeners: Array<() => void> = [];
export function onStateChange(fn: () => void): void {
  listeners.push(fn);
}

function reflect(): void {
  const theme = effectiveTheme();

  if (chosen) root.dataset.theme = chosen;
  else delete root.dataset.theme; // back to following the system

  // The animated cuts carry their own CSS: an <img> runs animation inside the
  // SVG but exposes nothing to page CSS, and the file's own
  // prefers-reduced-motion rule stops the sweep without JS involvement.
  for (const mark of document.querySelectorAll<HTMLImageElement>('[data-mark]')) {
    mark.src =
      theme === 'light'
        ? '/assets/pulsar-animated-color-dark.svg'
        : '/assets/pulsar-animated.svg';
  }

  for (const button of document.querySelectorAll<HTMLElement>('[data-theme-pick]')) {
    button.setAttribute('aria-pressed', String(button.dataset.themePick === theme));
  }
  for (const button of document.querySelectorAll<HTMLElement>('[data-look]')) {
    button.setAttribute('aria-pressed', String(Number(button.dataset.look) === look));
  }

  for (const fn of listeners) fn();
}

export function initTheme(): void {
  reflect();

  // Enable the pill's travel only after the first placement has painted. The
  // active theme is only known after storage and the system query are read, so
  // a transition enabled up front makes every load start on Dark and visibly
  // slide across.
  requestAnimationFrame(() => {
    root.dataset.ready = '1';
  });

  for (const button of document.querySelectorAll<HTMLElement>('[data-theme-pick]')) {
    button.addEventListener('click', () => {
      const pick = button.dataset.themePick;
      if (pick !== 'dark' && pick !== 'light') return;
      chosen = pick;
      store.set(THEME_KEY, chosen);
      reflect();
    });
  }

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

  sysLight.addEventListener('change', reflect);
}
