// Draws a share card: Satori lays it out with the faces the page loads,
// resvg rasterises it, sharp encodes the JPEG.
//
// This replaced a hand-run podman + EGL + Pillow script whose output was
// committed and then drifted from the brand. Now every card is rebuilt on every
// deploy from the same lockup, faces, screenshots and build data as the page.
//
// Everything is read from disk. Nothing is fetched, so the build works offline
// and the same inputs make the same bytes. Anything missing or wrong throws:
// a card that silently lost its fonts or its background would still deploy,
// and nobody would see it until it was in someone's feed.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Resvg } from '@resvg/resvg-js';
import satori from 'satori';
import sharp from 'sharp';
import { changelog } from '../data/build';
import { SITE as SITE_URL } from '../data/site';

const SITE_HOST = new URL(SITE_URL).host;
import { THEMES, variant } from '../data/themes';
import { buildDate, version, type Card, type Line } from './cards';

export const W = 1200;
export const H = 630; // the Open Graph standard size

/** Share cards are fetched by crawlers with budgets; keep each one small. */
const MAX_BYTES = 200 * 1024;

// The site's own tokens (src/styles/tokens.css): ink ground, star type,
// the cyan accent.
const INK = '#0B0E1A';
const DEEP = '#070912';
const STAR = '#E9EDF7';
const MUTED = '#A9B1CC';
const CYAN = '#3ECBFF';

// Read from the project root rather than from import.meta.url: this module is
// bundled into dist/.prerender/chunks before it runs, so a path relative to
// the source file resolves to somewhere that does not exist. `astro build`
// runs with the Astro project as its working directory, which is also what
// Cloudflare gives us (root directory `site`).
const SITE = process.cwd();
const REPO = join(SITE, '..');

function asset(...parts: string[]): Buffer {
  const path = join(...parts);
  try {
    return readFileSync(path);
  } catch (cause) {
    throw new Error(`og: cannot read ${path}`, { cause });
  }
}

const dataUri = (mime: string, buf: Buffer) => `data:${mime};base64,${buf.toString('base64')}`;

const HG = join(REPO, 'assets', 'fonts', 'Host_Grotesk', 'static');
const JB = join(REPO, 'assets', 'fonts', 'JetBrains_Mono', 'static');
const FONTS = [
  { name: 'Host Grotesk', data: asset(HG, 'HostGrotesk-Bold.ttf'), weight: 700 as const, style: 'normal' as const },
  { name: 'Host Grotesk', data: asset(HG, 'HostGrotesk-Regular.ttf'), weight: 400 as const, style: 'normal' as const },
  { name: 'JetBrains Mono', data: asset(JB, 'JetBrainsMono-Regular.ttf'), weight: 400 as const, style: 'normal' as const },
  { name: 'JetBrains Mono', data: asset(JB, 'JetBrainsMono-Bold.ttf'), weight: 700 as const, style: 'normal' as const },
];

// The authored horizontal lockup, drawn as-is: the card is a placement of
// the logo, not a second drawing of it. 1600x452, cropped to the art plus 3%.
const LOCKUP = dataUri('image/png', asset(REPO, 'assets', 'brand', 'png', 'pulsar-lockup-horizontal.png'));
const LOCKUP_RATIO = 1600 / 452;
// The mark alone, drawn huge and faint off the corner: the card's own
// lighthouse. Shrunk first, so a 1024px PNG does not blow the byte budget.
const MARK_SIZE = 900;
const MARK = dataUri(
  'image/png',
  await sharp(asset(REPO, 'assets', 'brand', 'png', 'pulsar-mark-1024.png')).resize(MARK_SIZE).png().toBuffer(),
);
const SILK = dataUri('image/jpeg', asset(SITE, 'assets-static', 'silk-still-dark.jpg'));
const GAMESCALE = dataUri('image/svg+xml', asset(SITE, 'assets-static', 'gamescale.svg'));

/** The smallest type any card may set: 11px on a 500px-wide feed preview,
    6.5px on a 300px thumbnail. Anything smaller is texture, not text, so
    h() refuses it and the build fails rather than ship a line nobody reads. */
const MIN_TEXT = 26;

/** Satori takes React-shaped nodes; this is the whole of what it needs. */
type Node = { type: string; props: Record<string, unknown> };
type Child = Node | string | null | false;
const h = (type: string, style: Record<string, unknown>, ...children: Child[]): Node => {
  if (typeof style.fontSize === 'number' && style.fontSize < MIN_TEXT) {
    throw new Error(`og: ${style.fontSize}px text is below the ${MIN_TEXT}px floor`);
  }
  return { type, props: { style, children: children.filter((c) => c !== null && c !== false) } };
};
const img = (src: string, width: number, height: number, style: Record<string, unknown> = {}): Node => ({
  type: 'img',
  props: { src, width, height, style },
});

// Satori cannot decode WebP, and a 1600px screenshot is far more than a
// 540px tile needs; sharp shrinks each one to twice its drawn size first.
async function desktopShot(slug: string, v: 'dark' | 'light', width: number): Promise<string> {
  const theme = THEMES.find((t) => t.slug === slug);
  if (!theme) throw new Error(`og: no theme "${slug}" in themes.json`);
  const src = variant(theme, v).desktop;
  if (!src) throw new Error(`og: theme "${slug}" has no ${v} desktop screenshot`);
  // "/assets/themes/<slug>/desktop-dark.webp" is staged from assets-static.
  const file = join(SITE, 'assets-static', src.replace(/^\/assets\//, ''));
  const jpeg = await sharp(asset(file))
    .resize({ width: width * 2 })
    .jpeg({ quality: 82, mozjpeg: true })
    .toBuffer();
  return dataUri('image/jpeg', jpeg);
}

const PAD = 64;

/** The ground every card shares: the silk still, darkened toward the type,
    and the footer's spectrum line along the bottom edge. */
function ground(scrim: string, ...children: Child[]): Node {
  return h(
    'div',
    { width: W, height: H, display: 'flex', position: 'relative', backgroundColor: INK, fontFamily: 'Host Grotesk' },
    img(SILK, W, H, { position: 'absolute', top: 0, left: 0, objectFit: 'cover' }),
    h('div', { position: 'absolute', top: 0, left: 0, width: W, height: H, display: 'flex', backgroundImage: scrim }),
    ...children,
    h('div', {
      position: 'absolute',
      left: 0,
      bottom: 0,
      width: W,
      height: 5,
      display: 'flex',
      backgroundImage: 'linear-gradient(90deg, #3ECBFF 0%, #8FA8FF 45%, #5B53E6 75%, #3ECBFF 100%)',
    }),
  );
}

/** The mark, huge and faint, bleeding off the top-right corner over a cyan
    bloom: behind everything, so the type never competes with it. */
const beacon = (): Node[] => [
  h('div', {
    position: 'absolute',
    top: -260,
    right: -260,
    width: 760,
    height: 760,
    display: 'flex',
    backgroundImage: 'radial-gradient(circle, rgba(62, 203, 255, 0.22) 0%, rgba(62, 203, 255, 0) 65%)',
  }),
  // far enough off the corner that the solid core is gone and only the lit
  // arc sweeps in above the URL
  img(MARK, MARK_SIZE, MARK_SIZE, { position: 'absolute', top: -520, right: -520, opacity: 0.32 }),
];

const lockup = (height: number) => img(LOCKUP, Math.round(height * LOCKUP_RATIO), height);


// ---- the poster ------------------------------------------------------------
// Each inner card is a poster: the page's promise is the picture, set as
// large as it fits, tight, with its closing phrase lit on a line of its own
// the way the site's .lift is. The one real command the page is about runs
// along the bottom as a quiet strip, the way a poster carries its small print.

// Host Grotesk Bold averages under 0.55em a character; JetBrains Mono's
// advance is exactly 0.6em. Satori clips nothing and reports nothing, so the
// layout is measured here from the same numbers it is drawn with, and a card
// that would not fit fails the build instead of shipping cut off.
const GROTESK = 0.55;
const MONO = 0.6;
const LEAD = 0.98;

/** Lines a run of words needs at a size: the fewest a greedy fill manages. */
function wrap(text: string, size: number, width: number): number {
  return balance(text.split(' ').filter(Boolean), size, width).length;
}

/** Breaks words into the fewest lines that fit, then evens them out: of every
    way to break into that many lines, the one whose longest line is shortest.
    A headline never ends on a lone short word, and no line runs long while
    the next sits nearly empty. Headlines are a handful of words, so trying
    every break is cheap. */
function balance(words: string[], size: number, width: number): string[] {
  const perLine = Math.floor(width / (size * GROTESK));
  const len = (ws: string[]) => ws.join(' ').length;
  if (!words.length) return [];
  let fewest = 1;
  let run = 0;
  for (const w of words) {
    if (run && run + 1 + w.length > perLine) {
      fewest += 1;
      run = w.length;
    } else run += (run ? 1 : 0) + w.length;
  }
  let best: string[][] | null = null;
  let bestScore = Infinity;
  const tryFrom = (at: number, left: number, acc: string[][]) => {
    if (left === 1) {
      const lines = [...acc, words.slice(at)];
      const lens = lines.map(len);
      if (Math.max(...lens) > perLine) return;
      // the longest line first, then how uneven the lines are
      const score = Math.max(...lens) * 1000 + (Math.max(...lens) - Math.min(...lens));
      if (score < bestScore) {
        bestScore = score;
        best = lines;
      }
      return;
    }
    for (let end = at + 1; end <= words.length - (left - 1); end++) tryFrom(end, left - 1, [...acc, words.slice(at, end)]);
  };
  tryFrom(0, fewest, []);
  return (best ?? [words]).map((ws) => ws.join(' '));
}

/** The headline's lines at a size: the plain part, then the lit part on its own. */
function headLines(card: Card, size: number, width: number): number {
  const lift = card.lift ?? '';
  const plain = card.headline.slice(0, card.headline.length - lift.length).trim();
  return wrap(plain, size, width) + wrap(lift, size, width);
}

/** The largest size, from a poster's to a sign's, whose headline fits the room. */
function fitHead(card: Card, width: number, room: number): number {
  for (const size of [112, 104, 96, 88, 80, 72, 66]) {
    const lines = headLines(card, size, width);
    if (lines <= 3 && lines * size * LEAD <= room) return size;
  }
  throw new Error(`og: card "${card.slug}" headline will not fit at any poster size; shorten it`);
}

// The site's .lift: the promise's key phrase in the accent, glowing, on a
// line of its own. Every line is broken here, balanced, and drawn as its own
// row, rather than left to Satori's greedy wrap.
function headline(text: string, size: number, maxWidth: number, lift = ''): Node {
  if (lift && !text.endsWith(lift)) throw new Error(`og: "${lift}" is not the end of "${text}"`);
  const words = (t: string) => t.split(' ').filter(Boolean);
  const plain = balance(words(text.slice(0, text.length - lift.length)), size, maxWidth);
  const lit = balance(words(lift), size, maxWidth);
  const row = (t: string, on: boolean) =>
    h(
      'div',
      on
        ? { display: 'flex', whiteSpace: 'pre', color: CYAN, textShadow: '0 0 36px rgba(62, 203, 255, 0.6)' }
        : { display: 'flex', whiteSpace: 'pre', color: STAR },
      t,
    );
  return h(
    'div',
    {
      display: 'flex',
      flexDirection: 'column',
      fontSize: size,
      fontWeight: 700,
      lineHeight: LEAD,
      letterSpacing: -0.025 * size,
      maxWidth,
    },
    ...plain.map((t) => row(t, false)),
    ...lit.map((t) => row(t, true)),
  );
}

const SUB = 30;
function sub(text: string, size = SUB): Node {
  return h('div', { display: 'flex', fontSize: size, fontWeight: 400, lineHeight: 1.3, color: MUTED, marginTop: 22 }, text);
}

// The small print: one real command on a hairline-topped strip, the prompt in
// cyan and its comment beside it. Sized to the longest thing it must hold,
// never under the floor.
const STRIP = 30;
function strip(line: Line, width: number, icon?: string): Node {
  const iconW = icon ? 56 + 20 : 0;
  const cols = 2 + line.cmd.length + (line.note ? 3 + line.note.length : 0);
  const size = Math.min(STRIP, Math.floor((width - iconW) / (cols * MONO)));
  if (size < MIN_TEXT) throw new Error(`og: "${line.cmd}" is too long for a card's strip (${size}px); shorten it`);
  return h(
    'div',
    {
      display: 'flex',
      alignItems: 'center',
      width,
      paddingTop: 22,
      borderTop: '1px solid rgba(143, 168, 255, 0.3)',
      fontFamily: 'JetBrains Mono',
      whiteSpace: 'pre',
    },
    icon ? img(GAMESCALE, 56, 56, { marginRight: 20 }) : null,
    h('span', { color: CYAN, fontSize: size }, '$ '),
    h('span', { color: STAR, fontSize: size }, line.cmd),
    line.note ? h('span', { color: MUTED, fontSize: size }, `   # ${line.note}`) : null,
  );
}

function buildStrip(width: number): Node {
  const s = changelog.summary;
  const counts = [
    s.added && `+${s.added} added`,
    s.upgraded && `${s.upgraded} upgraded`,
    s.downgraded && `${s.downgraded} downgraded`,
    s.changed && `${s.changed} changed`,
    s.removed && `−${s.removed} removed`,
  ].filter(Boolean) as string[];
  const tally = changelog.baseline ? 'first build' : counts.length ? counts.join(' · ') : 'nothing moved';
  return h(
    'div',
    {
      display: 'flex',
      alignItems: 'baseline',
      justifyContent: 'space-between',
      width,
      paddingTop: 22,
      borderTop: '1px solid rgba(143, 168, 255, 0.3)',
      fontFamily: 'JetBrains Mono',
    },
    h('span', { color: CYAN, fontSize: 30, fontWeight: 700 }, version),
    h('span', { color: MUTED, fontSize: 28 }, `${tally} · ${buildDate}`),
  );
}

function topRow(card: Card): Node {
  return h(
    'div',
    { display: 'flex', alignItems: 'center', justifyContent: 'space-between', width: W - 2 * PAD },
    lockup(64),
    h(
      'div',
      { display: 'flex', fontFamily: 'JetBrains Mono', fontSize: 26, color: MUTED },
      `${SITE_HOST}${card.path === '/' ? '' : card.path}`,
    ),
  );
}

const INNER_SCRIM = 'linear-gradient(180deg, rgba(11,14,26,0.55) 0%, rgba(11,14,26,0.35) 45%, rgba(11,14,26,0.85) 100%)';

async function inner(card: Card): Promise<Node> {
  const v = card.visual;
  const width = W - 2 * PAD;
  const top = PAD - 12;
  const STRIP_H = 22 + (v.kind === 'terminal' && v.icon ? 56 : STRIP * 1.3);
  // what the headline has once the lockup row, the sub, the strip and the
  // air between them are paid for
  const room = H - top - 64 - 40 - (card.sub ? 22 + SUB * 1.3 : 0) - 40 - STRIP_H - PAD;
  const size = fitHead(card, width - 60, room);

  let visual: Node;
  if (v.kind === 'terminal') visual = strip(v.line, width, v.icon);
  else if (v.kind === 'build') visual = buildStrip(width);
  else throw new Error(`og: card "${card.slug}" has a visual only the home card draws`);

  return ground(
    INNER_SCRIM,
    ...beacon(),
    h(
      'div',
      {
        position: 'absolute',
        top: 0,
        left: 0,
        width: W,
        height: H,
        padding: `${top}px ${PAD}px ${PAD}px`,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'space-between',
      },
      topRow(card),
      h(
        'div',
        { display: 'flex', flexDirection: 'column' },
        headline(card.headline, size, width - 60, card.lift),
        card.sub ? sub(card.sub) : null,
      ),
      visual,
    ),
  );
}

// The home card: the logo and the line on the left, the desktop in three
// themes fanned off the right edge. The screenshots are the theme harness's
// own, so the card shows the product rather than describing it.
async function home(card: Card): Promise<Node> {
  const v = card.visual;
  if (v.kind !== 'desktops' || v.themes.length !== 3) {
    throw new Error('og: the home card needs exactly three desktop screenshots');
  }
  const TW = 560;
  const TH = Math.round((TW * 1000) / 1600); // the screenshots are 16:10
  const shots = await Promise.all(v.themes.map((t) => desktopShot(t.slug, t.variant, TW)));
  // back to front, each one down and left of the last
  const at = [
    { top: 62, left: 720 },
    { top: 158, left: 668 },
    { top: 254, left: 616 },
  ];
  const tiles = shots.map((src, i) =>
    h(
      'div',
      {
        position: 'absolute',
        top: at[i].top,
        left: at[i].left,
        display: 'flex',
        borderRadius: 14,
        overflow: 'hidden',
        border: '1px solid rgba(233, 237, 247, 0.16)',
        boxShadow: '0 24px 60px rgba(0, 0, 0, 0.55)',
      },
      img(src, TW, TH),
    ),
  );

  return ground(
    'linear-gradient(90deg, rgba(11,14,26,0.82) 0%, rgba(11,14,26,0.55) 50%, rgba(11,14,26,0.2) 100%)',
    ...tiles,
    h(
      'div',
      {
        position: 'absolute',
        top: 0,
        left: 0,
        width: 600,
        height: H,
        padding: `0 0 0 ${PAD}px`,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'center',
      },
      lockup(84),
      h('div', { display: 'flex', height: 40 }),
      headline(card.headline, 64, 560, card.lift),
      card.sub ? sub(card.sub, 30) : null,
      h(
        'div',
        { display: 'flex', fontFamily: 'JetBrains Mono', fontSize: 26, color: MUTED, marginTop: 40 },
        SITE_HOST,
      ),
    ),
  );
}

/** Render one card to a JPEG, and refuse to return anything malformed. */
export async function renderCard(card: Card): Promise<Buffer> {
  const tree = card.visual.kind === 'desktops' ? await home(card) : await inner(card);
  const svg = await satori(tree as never, { width: W, height: H, fonts: FONTS });

  // resvg only emits PNG, the wrong container for a photographic ground (the
  // old single card was ~541KB as a PNG and ~45KB as a JPEG), so sharp does
  // the encode and nothing else.
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: W } }).render().asPng();
  const jpeg = await sharp(png)
    .flatten({ background: DEEP })
    .jpeg({ quality: 84, progressive: true, mozjpeg: true, chromaSubsampling: '4:4:4' })
    .toBuffer();

  const meta = await sharp(jpeg).metadata();
  if (meta.width !== W || meta.height !== H || meta.format !== 'jpeg') {
    throw new Error(`og: card "${card.slug}" came out ${meta.width}x${meta.height} ${meta.format}`);
  }
  if (jpeg.length > MAX_BYTES) {
    throw new Error(`og: card "${card.slug}" is ${Math.round(jpeg.length / 1024)}KB, over the ${MAX_BYTES / 1024}KB budget`);
  }
  return jpeg;
}
