// The themes the image ships, as the site shows them. themes.json is built
// from the theme definitions in the image (palettes read from each
// theme.toml) and every picture it names is shader output: the wallpaper
// stills are the same fragment shader that draws the hero, rendered in each
// palette, and the desktop shots are the theme harness's own screenshots.
// So the showcase bends the "shader and its still only" rule without breaking
// it -- every image here is one the OS itself produces.
//
// Dracula and Alucard are two themes, not one: Dracula is dark only and
// Alucard light only, so neither follows the Dark Style toggle and choosing
// either is a full switch. A single-variant theme shows the variant it has
// whichever mode the page is in.
//
// TODO(alucard-shot): no harness screenshot of Alucard exists yet, so its
// preview shows its wallpaper; add desktop-light.webp when one is taken.
import raw from './themes.json';

export type Variant = {
  swatch: string[];
  accent: string;
  bg: string;
  deep: string;
  raised: string;
  fg: string;
  wall?: string;
  desktop?: string;
};

export type Theme = {
  slug: string;
  name: string;
  author: string;
  prefer: string;
  /** TODO(phosphor-amber-assets): a provisional palette with no pictures yet */
  placeholder?: boolean;
  variants: { dark?: Variant; light?: Variant };
};

export const THEMES = raw as Theme[];

// Display names that differ from the definition's, for the pairs whose
// variants carry their own names upstream.
const LABEL: Record<string, string> = {
  catppuccin: 'Catppuccin',
};
export const label = (t: Theme) => LABEL[t.slug] ?? t.name;

export const variant = (t: Theme, v: 'dark' | 'light'): Variant =>
  (t.variants[v] ?? t.variants.dark ?? t.variants.light) as Variant;

export const setCommand = (t: Theme) => `pulsar theme set ${t.slug}`;

// The attributes src/scripts/themes.ts reads off anything that picks a theme,
// so the showcase tiles and both hero options carry exactly the same data.
export const tileAttrs = (t: Theme) => ({
  'data-theme-tile': t.slug,
  'data-name': label(t),
  'data-dark': JSON.stringify(variant(t, 'dark')),
  'data-light': JSON.stringify(variant(t, 'light')),
});

// "#3ecbff" -> "62, 203, 255", the -rgb twin ARC's contract asks for.
export const rgb = (hex: string) => {
  const n = parseInt(hex.replace('#', ''), 16);
  return `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
};
