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
/** The inner cards' headline size: 16px at a 300px-wide thumbnail. */
const HEAD = 66;

/** The ground every card shares: the silk still, darkened toward the type. */
function ground(scrim: string, ...children: Child[]): Node {
  return h(
    'div',
    { width: W, height: H, display: 'flex', position: 'relative', backgroundColor: INK, fontFamily: 'Host Grotesk' },
    img(SILK, W, H, { position: 'absolute', top: 0, left: 0, objectFit: 'cover' }),
    h('div', { position: 'absolute', top: 0, left: 0, width: W, height: H, display: 'flex', backgroundImage: scrim }),
    ...children,
  );
}

const lockup = (height: number) => img(LOCKUP, Math.round(height * LOCKUP_RATIO), height);

function headline(text: string, size: number, maxWidth: number): Node {
  return h(
    'div',
    {
      display: 'flex',
      fontSize: size,
      fontWeight: 700,
      lineHeight: 1.06,
      letterSpacing: -0.015 * size,
      color: STAR,
      maxWidth,
    },
    text,
  );
}

function sub(text: string, size = 30): Node {
  return h('div', { display: 'flex', fontSize: size, fontWeight: 400, lineHeight: 1.3, color: MUTED, marginTop: 18 }, text);
}

// The page's dark code block: deep ink, a hairline in periwinkle, a soft
// cyan glow under it. No window chrome, and no language label: at thumbnail
// size a label is a smudge, and the $ already says what this is.
function panel(...children: Child[]): Node {
  return h(
    'div',
    {
      display: 'flex',
      flexDirection: 'column',
      backgroundColor: 'rgba(7, 9, 18, 0.9)',
      border: '1px solid rgba(143, 168, 255, 0.28)',
      borderRadius: 18,
      boxShadow: '0 0 60px rgba(62, 203, 255, 0.14)',
      padding: '26px 32px',
    },
    ...children,
  );
}

// JetBrains Mono's advance is 0.6em, so a line's width is known from its length.
const MONO_ADVANCE = 0.6;
const NOTE_SCALE = 0.8;
const NOTE_GAP = 40;

function termLine(line: Line, size: number, cmdCols: number): Node {
  return h(
    'div',
    { display: 'flex', alignItems: 'baseline', fontFamily: 'JetBrains Mono', lineHeight: 1.5, whiteSpace: 'pre' },
    h('span', { color: CYAN, fontSize: size, marginRight: size * MONO_ADVANCE }, '$'),
    // Commands share one column width, so their comments line up.
    h(
      'span',
      line.note
        ? { color: STAR, fontSize: size, width: cmdCols * size * MONO_ADVANCE + NOTE_GAP }
        : { color: STAR, fontSize: size },
      line.cmd,
    ),
    line.note ? h('span', { color: MUTED, fontSize: Math.round(size * NOTE_SCALE) }, `# ${line.note}`) : null,
  );
}

/** Characters in the widest command, and that plus its comment in px per em. */
function termMeasure(lines: Line[]) {
  const cmdCols = Math.max(...lines.map((l) => l.cmd.length));
  const noteCols = Math.max(0, ...lines.map((l) => (l.note ? l.note.length + 2 : 0)));
  // in em of the command size: "$ " + the command column + gap + the comment
  const ems = (2 + cmdCols) * MONO_ADVANCE + (noteCols ? noteCols * MONO_ADVANCE * NOTE_SCALE : 0);
  return { cmdCols, ems, gap: noteCols ? NOTE_GAP : 0 };
}

/** The widest line sets the terminal's type size, up to a comfortable maximum.
    Its comments are set smaller, and they have to clear the floor too. */
function termSize(lines: Line[], width: number): number {
  const { ems, gap } = termMeasure(lines);
  const size = Math.min(36, Math.floor((width - 64 - gap) / ems));
  const least = lines.some((l) => l.note) ? Math.ceil(MIN_TEXT / NOTE_SCALE) : MIN_TEXT;
  if (size < least) throw new Error(`og: a terminal line is too long to read on a card (${size}px); shorten it`);
  return size;
}

// Satori clips nothing and reports nothing: a card whose content runs off
// the bottom renders without complaint. So the inner layout is budgeted here
// from the same numbers it is drawn with, and a card that would not fit fails
// the build instead. Host Grotesk Bold averages under 0.55em a character.
function assertFits(card: Card, headSize: number, width: number, visualHeight: number) {
  const perLine = Math.floor(width / (headSize * 0.55));
  const words = card.headline.split(' ');
  let lines = 1;
  let run = 0;
  for (const w of words) {
    if (run && run + 1 + w.length > perLine) {
      lines += 1;
      run = w.length;
    } else run += (run ? 1 : 0) + w.length;
  }
  if (lines > 2) throw new Error(`og: card "${card.slug}" headline runs to ${lines} lines; keep it to two`);
  const used =
    (PAD - 12) + 64 + // top padding and the lockup row
    lines * headSize * 1.06 + (card.sub ? 18 + 30 * 1.3 : 0) +
    visualHeight + PAD +
    2 * 28; // the least breathing room between the three rows
  if (used > H) throw new Error(`og: card "${card.slug}" needs ${Math.round(used)}px of ${H}; shorten it`);
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

const INNER_SCRIM = 'linear-gradient(180deg, rgba(11,14,26,0.55) 0%, rgba(11,14,26,0.35) 45%, rgba(11,14,26,0.8) 100%)';

async function inner(card: Card): Promise<Node> {
  const v = card.visual;
  const width = W - 2 * PAD;
  let visual: Node;

  // the panel's chrome: its padding, top and bottom
  const PANEL = 26 + 26;
  if (v.kind === 'terminal') {
    const iconW = v.icon ? 112 + 36 : 0;
    const size = termSize(v.lines, width - iconW);
    const { cmdCols } = termMeasure(v.lines);
    assertFits(card, HEAD, width, PANEL + v.lines.length * size * 1.5);
    const block = panel(...v.lines.map((l) => termLine(l, size, cmdCols)));
    visual = v.icon
      ? h(
          'div',
          { display: 'flex', alignItems: 'center' },
          img(GAMESCALE, 112, 112, { marginRight: 36 }),
          h('div', { display: 'flex', flexGrow: 1, flexDirection: 'column' }, block),
        )
      : block;
  } else if (v.kind === 'build') {
    const s = changelog.summary;
    const counts = [
      s.added && `+${s.added} added`,
      s.upgraded && `${s.upgraded} upgraded`,
      s.downgraded && `${s.downgraded} downgraded`,
      s.changed && `${s.changed} changed`,
      s.removed && `−${s.removed} removed`,
    ].filter(Boolean) as string[];
    const tally = changelog.baseline ? 'First build.' : counts.length ? counts.join('  ·  ') : 'Nothing moved.';
    assertFits(card, HEAD, width, PANEL + 60 * 1.1 + 10 + 28 * 1.2);
    visual = panel(
      h(
        'div',
        { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' },
        h('div', { display: 'flex', fontFamily: 'JetBrains Mono', fontWeight: 700, fontSize: 60, color: CYAN, lineHeight: 1.1 }, version),
        h('div', { display: 'flex', fontSize: 30, color: STAR }, buildDate),
      ),
      h('div', { display: 'flex', fontFamily: 'JetBrains Mono', fontSize: 28, color: MUTED, marginTop: 10 }, tally),
    );
  } else {
    throw new Error(`og: card "${card.slug}" has a visual only the home card draws`);
  }

  return ground(
    INNER_SCRIM,
    h(
      'div',
      {
        position: 'absolute',
        top: 0,
        left: 0,
        width: W,
        height: H,
        padding: `${PAD - 12}px ${PAD}px ${PAD}px`,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'space-between',
      },
      topRow(card),
      h(
        'div',
        { display: 'flex', flexDirection: 'column' },
        headline(card.headline, HEAD, width),
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
      headline(card.headline, 58, 500),
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
