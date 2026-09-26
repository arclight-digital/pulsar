// Picking a theme -- from the floating picker, the showcase tiles or a hero
// control -- recolours the WHOLE site (scripts/sitetheme.ts), swaps the
// showcase preview to that theme's desktop, and follows it with the command.
//
// One source of truth for "which theme is showing": a pulsar:theme event on
// document. Everything that picks dispatches it and everything that shows
// listens, so the picker, the tiles and the hero cannot drift. The choice is
// remembered per visitor (sitetheme.ts); a reset is Pulsar again.
import { applySiteTheme, storedTheme } from './sitetheme';

type Variant = { accent: string; desktop?: string; wall?: string };
export type ThemeDetail = { slug: string; name: string; dark: Variant; light: Variant };

// Mirrors the page's own theme resolution: an explicit data-theme wins,
// `auto` follows the OS.
export const mode = (): 'dark' | 'light' => {
  const t = document.documentElement.dataset.theme;
  if (t === 'light' || t === 'dark') return t;
  return matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
};

let current: ThemeDetail | null = null;

function show(detail: ThemeDetail) {
  current = detail;
  applySiteTheme(detail.slug);
  preview(detail);
}

// The parts that depend on the page's mode as well as the theme. Kept apart
// from show() so the light/dark observer can refresh them without
// re-applying the theme -- which, for a single-mode theme, sets the mode, and
// would feed the observer forever.
function preview(detail: ThemeDetail) {
  const v = detail[mode()] ?? detail.dark ?? detail.light;
  // A theme with no desktop screenshot yet shows its wallpaper instead, so the
  // preview never keeps showing the previous theme under the new one's name.
  const src = v.desktop ?? v.wall;
  const alt = v.desktop
    ? `The Pulsar desktop in the ${detail.name} theme`
    : `The ${detail.name} wallpaper`;
  document.querySelectorAll<HTMLImageElement>('[data-preview]').forEach((img) => {
    if (!src || img.getAttribute('src') === src) return;
    img.dataset.loading = '';
    img.onload = () => delete img.dataset.loading;
    img.src = src;
    img.alt = alt;
  });
  document.querySelectorAll('[data-preview-name]').forEach((el) => (el.textContent = detail.name));
  const cmd = `pulsar theme set ${detail.slug}`;
  document.querySelectorAll('[data-preview-cmd]').forEach((el) => {
    // an ARC code block takes the command as its attribute; a caption is text
    if (el.tagName === 'ARC-CODE-BLOCK') el.setAttribute('code', cmd);
    else el.textContent = cmd;
  });
  document.querySelectorAll<HTMLElement>('[data-theme-tile]').forEach((b) =>
    b.setAttribute('aria-pressed', b.dataset.themeTile === detail.slug ? 'true' : 'false'),
  );
}

export const detailOf = (el: HTMLElement): ThemeDetail => ({
  slug: el.dataset.themeTile ?? 'pulsar',
  name: el.dataset.name ?? '',
  dark: JSON.parse(el.dataset.dark ?? '{}'),
  light: JSON.parse(el.dataset.light ?? '{}'),
});

export function pick(detail: ThemeDetail) {
  document.dispatchEvent(new CustomEvent<ThemeDetail>('pulsar:theme', { detail }));
  if (detail.slug !== 'pulsar') tellOnce(detail.slug);
}

// Once a session, the first time someone picks a theme: where the same thing
// lives on a real Pulsar desktop. First login binds Super+Shift+T only when
// the key is free, so the line names the command too, which always works.
function tellOnce(slug: string) {
  try {
    if (sessionStorage.getItem('pulsar-theme-told')) return;
    sessionStorage.setItem('pulsar-theme-told', '1');
  } catch {
    /* no session storage: say it anyway, once per page */
  }
  const toast = document.querySelector<HTMLElement & { show?: (o: object) => void }>('[data-theme-toast]');
  const cmd = `pulsar theme set ${slug}`;
  toast?.show?.({
    message: `In Pulsar: Super+Shift+T, or ${cmd}`,
    duration: 9000,
    actionLabel: 'Copy command',
    action: () => {
      navigator.clipboard?.writeText(cmd).catch(() => {});
    },
  });
}

export function initThemes(): void {
  document.addEventListener('pulsar:theme', (e) => show((e as CustomEvent<ThemeDetail>).detail));
  document.addEventListener('click', (e) => {
    const target = e.target as HTMLElement;
    const tile = target.closest<HTMLElement>('[data-theme-tile]');
    if (tile) return pick(detailOf(tile));
    // A ‹ theme › stepper walks the gallery's own order, so it and the
    // tiles can never disagree about what comes next.
    const step = target.closest<HTMLElement>('[data-stepper] [data-step]');
    if (!step) return;
    const tiles = [...document.querySelectorAll<HTMLElement>('#themes [data-theme-tile]')];
    if (!tiles.length) return;
    const at = Math.max(0, tiles.findIndex((t) => t.dataset.themeTile === (current?.slug ?? tiles[0].dataset.themeTile)));
    const next = (at + Number(step.dataset.step) + tiles.length) % tiles.length;
    pick(detailOf(tiles[next]));
  });
  // The page's own light/dark toggle changes which accent and which shot is
  // right for the theme on show; re-apply it rather than leave a dark accent
  // on a light page.
  new MutationObserver(() => current && preview(current)).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });

  // A theme remembered from an earlier page: the pre-paint script already put
  // its colours on; this re-applies (a new build may have refined them) and
  // brings the picker, tiles and preview into line. No toast -- nothing was
  // picked just now.
  const stored = storedTheme();
  const tile = stored && document.querySelector<HTMLElement>(`[data-theme-tile="${CSS.escape(stored)}"]`);
  if (tile) show(detailOf(tile));

  // the floating picker: open it, and "Back to Pulsar"
  document.addEventListener('click', (e) => {
    const target = e.target as HTMLElement;
    if (target.closest('[data-picker-open]')) {
      const sheet = document.querySelector<HTMLElement & { open: boolean }>('[data-picker]');
      if (sheet) sheet.open = true;
    }
    if (target.closest('[data-picker-reset]')) {
      const home = document.querySelector<HTMLElement>('[data-theme-tile="pulsar"]');
      if (home) show(detailOf(home));
      document.dispatchEvent(new Event('pulsar:reset'));
    }
  });

  // for the review screenshots and the audit: window.pulsarTheme('nord')
  (window as unknown as { pulsarTheme: (s: string) => void }).pulsarTheme = (s: string) => {
    const t = document.querySelector<HTMLElement>(`[data-theme-tile="${CSS.escape(s)}"]`);
    if (t) show(detailOf(t));
  };
}
