// Picking a theme on the page: the showcase preview swaps to that theme's
// desktop, the command follows it, and the page itself takes the theme's
// accent through ARC's two-colour contract -- the same two tokens every ARC
// component reads, so nothing's parts are restyled, only re-fed.
//
// One source of truth for "which theme is showing": a pulsar:theme event on
// document. The showcase tiles and the hero options (sky stills, the split
// hero's switcher) both dispatch it and both listen, so they cannot drift.
//
// Nothing here is persisted. A visitor recolouring the page is looking, not
// choosing; a reload is Pulsar again.

type Variant = { accent: string; desktop?: string; wall?: string };
export type ThemeDetail = { slug: string; name: string; dark: Variant; light: Variant };

const rgb = (hex: string) => {
  const n = parseInt(hex.replace('#', ''), 16);
  return `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
};

// Mirrors the page's own theme resolution: an explicit data-theme wins,
// `auto` follows the OS.
export const mode = (): 'dark' | 'light' => {
  const t = document.documentElement.dataset.theme;
  if (t === 'light' || t === 'dark') return t;
  return matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
};

let current: ThemeDetail | null = null;

function recolour(detail: ThemeDetail | null) {
  const root = document.documentElement.style;
  if (!detail || detail.slug === 'pulsar') {
    // Pulsar is the page's own palette: drop the overrides, let tokens.css
    // speak, so light mode keeps its violet rather than a borrowed accent.
    for (const p of ['--accent-primary', '--accent-primary-rgb', '--accent-secondary', '--accent-secondary-rgb'])
      root.removeProperty(p);
    return;
  }
  const a = detail[mode()].accent;
  root.setProperty('--accent-primary', a);
  root.setProperty('--accent-primary-rgb', rgb(a));
  root.setProperty('--accent-secondary', a);
  root.setProperty('--accent-secondary-rgb', rgb(a));
}

function show(detail: ThemeDetail) {
  current = detail;
  recolour(detail);
  const v = detail[mode()];
  document.querySelectorAll<HTMLImageElement>('[data-preview]').forEach((img) => {
    if (!v.desktop || img.getAttribute('src') === v.desktop) return;
    img.dataset.loading = '';
    img.onload = () => delete img.dataset.loading;
    img.src = v.desktop;
    img.alt = `The Pulsar desktop in the ${detail.name} theme`;
  });
  document.querySelectorAll('[data-preview-name]').forEach((el) => (el.textContent = detail.name));
  document.querySelectorAll('[data-preview-cmd]').forEach((el) => el.setAttribute('code', `pulsar theme set ${detail.slug}`));
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
}

export function initThemes(): void {
  document.addEventListener('pulsar:theme', (e) => show((e as CustomEvent<ThemeDetail>).detail));
  document.addEventListener('click', (e) => {
    const tile = (e.target as HTMLElement).closest<HTMLElement>('[data-theme-tile]');
    if (tile) pick(detailOf(tile));
  });
  // The page's own light/dark toggle changes which accent and which shot is
  // right for the theme on show; re-apply it rather than leave a dark accent
  // on a light page.
  new MutationObserver(() => current && show(current)).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });
}
