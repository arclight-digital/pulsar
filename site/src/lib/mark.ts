// The Pulsar mark, inlined at build time and wired to the page's theme.
//
// As an <img> the mark could not follow the site's theme picker: an image is
// a sealed box to CSS. Inlined, its gradient stops take their colour from
// ARC's two-colour contract (--accent-primary / --accent-secondary), so the
// mark wears whichever theme the page wears, and on Pulsar's own theme it is
// exactly the brand drawing: the brand hexes map onto the slots those same
// hexes fill by default (cyan and periwinkle on dark, violet on light).
//
// Every cut shares one of two palettes (the colour-on-dark family and the
// deep-violet-core -light family), so one table each covers every size. The
// neutrals (white, star, the deep core) stay as drawn: they are the light
// source and the ink, not the brand's accent.
//
// A page carries several marks, and SVG ids are document-global: two inlined
// copies of the same drawing would each point url(#pg) at whichever gradient
// the document found first -- a hidden one, on a theme flip. Every id is
// prefixed per copy.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Read from the staged copies (stage-assets.mjs runs before every build and
// dev start), which include the light hero mark re-boxed onto the dark one's
// canvas so the two swap without the core jumping.
const ASSETS = join(process.cwd(), 'public', 'assets');

const ON_DARK: Record<string, string> = {
  '#3ecbff': 'var(--accent-primary)',
  '#8aaaff': 'var(--accent-secondary)',
  '#8fa8ff': 'var(--accent-secondary)',
  // the arc's deep end and the halo's near-white: the accents, darkened and lit
  '#5b53e6': 'color-mix(in oklab, var(--accent-secondary) 58%, var(--ink))',
  '#8fd8ff': 'color-mix(in oklab, var(--accent-primary) 62%, var(--star))',
  '#c4e9ff': 'color-mix(in oklab, var(--accent-primary) 28%, var(--star))',
};

const ON_LIGHT: Record<string, string> = {
  '#4b3fd4': 'var(--accent-primary)',
  '#7782f3': 'color-mix(in oklab, var(--accent-primary) 55%, var(--accent-secondary))',
  '#8fd2ff': 'color-mix(in oklab, var(--accent-secondary) 50%, var(--star))',
};

let copies = 0;

export function markSvg(file: string, light: boolean): string {
  const map = light ? ON_LIGHT : ON_DARK;
  const uid = `mk${++copies}`;
  let svg = readFileSync(join(ASSETS, file), 'utf8');
  svg = svg
    .replace(/<metadata>[\s\S]*?<\/metadata>/g, '')
    .replace(/\s+xmlns:c2pa="[^"]*"/g, '')
    // sized by the component's box, not the drawing's own numbers
    .replace(/<svg\b([^>]*?)\s+width="[^"]*"/, '<svg$1')
    .replace(/<svg\b([^>]*?)\s+height="[^"]*"/, '<svg$1')
    .replace(/<svg\b/, '<svg aria-hidden="true" focusable="false"')
    .replace(/\bid="([^"]+)"/g, `id="${uid}-$1"`)
    .replace(/url\(#([^)]+)\)/g, `url(#${uid}-$1)`)
    .replace(/href="#([^"]+)"/g, `href="#${uid}-$1"`)
    .replace(/\b(stop-color|fill|stroke)="(#[0-9a-fA-F]{3,6})"/g, (whole, prop: string, hex: string) => {
      const value = map[hex.toLowerCase()];
      return value ? `style="${prop}:${value}"` : whole;
    });
  return svg;
}
