// The site in a Pulsar theme: one theme's palette in, the full set of ARC
// tokens out -- surfaces, text ramp, borders, accents, the chip family, the
// code blocks -- as a stylesheet. Never ARC's parts: only the tokens its
// two-colour contract and base.css already read.
//
// Contrast is fitted, not hoped for. Every text token is checked against the
// surface it sits on and pulled toward the foreground until it clears WCAG AA
// (4.5:1); the link/accent colour is pulled the same way. So a low-contrast
// palette (Solarized, Everforest light) still reads, and the theme stays
// recognisably itself -- only lightness moves, toward its own foreground.
//
// Selectors are prefixed `html:root` so they outrank both tokens.css and
// ARC's [data-theme] rules whatever order the stylesheets land in -- the
// pre-paint script inserts this before the stylesheets load.
import type { Theme, Variant } from './themes';

type RGB = [number, number, number];

const hex = (h: string): RGB => {
  const n = parseInt(h.replace('#', ''), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const toHex = ([r, g, b]: RGB) =>
  '#' + [r, g, b].map((v) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, '0')).join('');
const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const lum = ([r, g, b]: RGB) => {
  const c = (v: number) => {
    const s = v / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b);
};
export const contrast = (a: RGB, b: RGB) => {
  const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
};

// Move `c` toward `toward` until it clears `min` against every surface.
function fit(c: RGB, toward: RGB, surfaces: RGB[], min = 4.6): RGB {
  let out = c;
  for (let t = 0; t <= 1.0001; t += 0.04) {
    out = mix(c, toward, t);
    if (surfaces.every((s) => contrast(out, s) >= min)) return out;
  }
  return toward;
}

const rgbList = (c: RGB) => c.map((v) => Math.round(v)).join(', ');

function tokens(v: Variant, light: boolean): string {
  const bg = hex(v.bg);
  const deep = hex(v.deep);
  const raised = hex(v.raised);
  const fg = hex(v.fg);
  const accent = hex(v.accent);
  // Text lands on more than the three named surfaces: ARC's badge fill and
  // the changelog's version highlight are the ground nudged toward the text
  // or the accent. Fit every text token against those as well.
  const surfaces = [bg, deep, raised, mix(bg, fg, 0.14), mix(raised, fg, 0.1), mix(bg, accent, 0.14)];
  // Accent text also sits on accent-tinted fills (ARC's primary badge, the
  // active nav item, a highlighted table row), so it is fitted against those
  // too, with a little headroom.
  const tinted = [mix(bg, accent, 0.18), mix(raised, accent, 0.18), mix(deep, accent, 0.18)];
  // Dark themes need more: ARC's primary badge and active nav item paint a
  // mix of the accent, not the accent itself, and that mix has to clear AA.
  const accentText = fit(accent, fg, [...surfaces, ...tinted], light ? 4.8 : 7.5);
  // text ON an accent fill (a pressed control): whichever of the theme's
  // ends reads best against the accent
  const onAccent = [deep, fg, bg].sort((a, b) => contrast(b, accentText) - contrast(a, accentText))[0];
  const secondary = fit(mix(fg, bg, 0.22), fg, surfaces);
  const muted = fit(mix(fg, bg, 0.3), fg, surfaces);
  const ghost = fit(mix(fg, bg, 0.36), fg, surfaces);
  const card = light ? mix(raised, [255, 255, 255], 0.35) : raised;
  const elevated = light ? mix(raised, [255, 255, 255], 0.55) : mix(raised, fg, 0.04);
  return [
    `--accent-primary: ${toHex(accentText)}`,
    `--accent-primary-rgb: ${rgbList(accentText)}`,
    `--accent-secondary: ${toHex(accent)}`,
    `--accent-secondary-rgb: ${rgbList(accent)}`,
    `--bg-deep: ${toHex(deep)}`,
    `--bg-surface: ${toHex(bg)}`,
    `--bg-base: ${toHex(bg)}`,
    `--bg-card: ${toHex(card)}`,
    `--bg-elevated: ${toHex(elevated)}`,
    `--text-primary: ${toHex(fg)}`,
    `--text-primary-rgb: ${rgbList(fg)}`,
    `--text-secondary: ${toHex(secondary)}`,
    `--text-muted: ${toHex(muted)}`,
    `--text-ghost: ${toHex(ghost)}`,
    `--border-subtle: rgba(${rgbList(accent)}, 0.14)`,
    `--border-default: rgba(${rgbList(accent)}, 0.22)`,
    `--border-default-rgb: ${rgbList(accent)}`,
    `--border-bright: rgba(${rgbList(accent)}, 0.36)`,
    // the brand family the site's own components use: accent glows, the
    // spectrum line, the build chip
    // The brand cyan also lives on the dark chips over the sky (the build
    // chip, the look deck), which stay dark in light mode too. A light
    // theme's accent is fitted dark for its pale page, so light themes keep
    // the brand cyan there; dark themes take their own.
    // ARC has its own --on-accent (white); this one is the site's.
    ...(light ? [] : [`--pulsar-on-accent: ${toHex(onAccent)}`, `--cyan: ${toHex(accentText)}`]),
    `--peri: ${toHex(mix(accent, fg, 0.35))}`,
    `--violet: ${toHex(mix(accent, deep, 0.35))}`,
  ].join('; ');
}

// Code blocks and the other theme-fixed-dark islands: the theme's dark
// variant when it has one, so a terminal still looks like a terminal.
function fixedDark(v: Variant): string {
  const bg = hex(v.bg);
  const deep = hex(v.deep);
  const raised = hex(v.raised);
  const fg = hex(v.fg);
  const surfaces = [bg, deep, raised];
  // ARC re-derives the accent inside a fixed-dark region from the brand
  // colour at a fixed lightness (base.css, the @supports block), which knows
  // nothing about this palette; so the region gets the theme's own accent,
  // fitted to its dark surfaces with the same headroom as the page.
  const accent = hex(v.accent);
  const tinted = surfaces.map((x) => mix(x, accent, 0.18));
  const accentText = fit(accent, fg, [...surfaces, ...tinted], 7.5);
  return [
    `--accent-primary: ${toHex(accentText)}`,
    `--accent-primary-rgb: ${rgbList(accentText)}`,
    `--accent-secondary: ${toHex(accent)}`,
    `--accent-secondary-rgb: ${rgbList(accent)}`,
    `--bg-deep: ${toHex(mix(deep, [0, 0, 0], 0.2))}`,
    `--bg-surface: ${toHex(deep)}`,
    `--bg-base: ${toHex(deep)}`,
    `--bg-card: ${toHex(bg)}`,
    `--bg-elevated: ${toHex(raised)}`,
    `--text-primary: ${toHex(fg)}`,
    `--text-secondary: ${toHex(fit(mix(fg, bg, 0.3), fg, surfaces))}`,
    `--text-muted: ${toHex(fit(mix(fg, bg, 0.34), fg, surfaces))}`,
    `--text-ghost: ${toHex(fit(mix(fg, bg, 0.38), fg, surfaces))}`,
    `--border-subtle: ${toHex(mix(deep, fg, 0.08))}`,
    `--border-default: ${toHex(mix(deep, fg, 0.13))}`,
    `--border-bright: ${toHex(mix(deep, fg, 0.22))}`,
  ].join('; ');
}

// The whole stylesheet for one theme. Two-variant themes follow the site's
// own light/dark toggle; a single-mode theme wears its one variant in both,
// and the picker sets the page's mode to match (see scripts/sitetheme.ts).
export function cssFor(t: Theme): string {
  const d = t.variants.dark;
  const l = t.variants.light;
  const dark = tokens((d ?? l)!, !d);
  const light = tokens((l ?? d)!, !!l);
  const rules = [
    `html:root[data-theme='dark'] { ${dark} }`,
    `html:root[data-theme='light'] { ${light} }`,
    `@media (prefers-color-scheme: dark) { html:root[data-theme='auto'] { ${dark} } }`,
    `@media (prefers-color-scheme: light) { html:root[data-theme='auto'] { ${light} } }`,
  ];
  if (d) rules.push(`html:root .theme-fixed-dark { ${fixedDark(d)} }`);
  return rules.join('\n');
}

/** 'dark' | 'light' for a single-mode theme, else null */
export const onlyMode = (t: Theme): 'dark' | 'light' | null =>
  t.variants.dark && t.variants.light ? null : t.variants.dark ? 'dark' : 'light';
