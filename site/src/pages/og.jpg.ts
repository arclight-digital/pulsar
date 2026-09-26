// The share card, rendered at build time instead of by hand.
//
// This used to be scripts/render-og.py: a podman + EGL + moderngl job that
// rendered the shader at card size, set the type with Pillow, and wrote a JPEG
// that was then committed. Pixels do not update themselves, so the card drifted
// -- it was set in Medium at 0.59em of tracking while the brand and the page
// both say Host Grotesk Bold at 0.2em.
//
// Now it is an Astro endpoint. Satori lays the card out with the same fonts the
// page loads and the same tokens the page is styled from, resvg rasterises it,
// sharp encodes it, and it is rebuilt on every deploy. There is nothing left
// to keep in sync.
//
// The background is the committed silk still rather than a live shader render:
// resvg cannot run WebGL, and the still is itself an output of that same
// shader, so the card and the hero are still showing the same field.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Resvg } from '@resvg/resvg-js';
import satori from 'satori';
import sharp from 'sharp';

export const prerender = true;

const W = 1200;
const H = 630; // the Open Graph standard size

const STAR = '#E9EDF7';
const INK = '#0B0E1A';
const TAGLINE = 'Your lighthouse in the sky.';

// Proportions taken from the authored lockup, assets/brand/svg/pulsar-lockup-stacked.svg.
// v2's wordmark is outlines, not <text>, so there is no font-size to read off
// it; these are measured off its rendered ink (alpha at 50%) instead, in the
// mark's own 256-unit drawing grid, which the lockup draws at scale 1 -- its
// mark's ink lands on exactly the same coordinates as pulsar-mark.svg's:
//
//   mark box     221.01 square (pulsar-mark.svg's viewBox, = pulsar-mark-1024.png)
//   mark ink     21.25 below the box top, 19.35 above the box bottom
//   wordmark     cap height 50.47, cap top 92.95 below the mark's lowest ink
//                (the package README's "about 1.4x below the trail")
//   tracking     0.24em (README; the outlines carry it, the number is theirs)
//
// Everything below is those numbers scaled by one factor, so the card is a
// rendering of the lockup at card scale rather than a second set of hand-tuned
// values that can disagree with it. Re-measure if the lockup is re-drawn.
const GRID = {
  box: 221.01,
  boxLeft: 24.5, // viewBox x; the core is at x = 128
  inkTop: 21.25,
  inkBottom: 19.35,
  cap: 50.47,
  capGap: 92.95,
};
const TRACK_EM = 0.24;

// Host Grotesk's OS/2 capHeight is 700 of 1000 units: a cap height of c needs
// a font-size of c / 0.7.
const CAP_PER_EM = 0.7;

// The box size sets the scale. 240 keeps the mark's INK the size it was on the
// v1 card (~195px): v1's file had wide margins, v2's is cropped to the art.
const MARK_SIZE = 240;
const UNIT = MARK_SIZE / GRID.box; // card px per grid unit
const WORD_SIZE = Math.round((GRID.cap * UNIT) / CAP_PER_EM); // 78
const TRACKING = WORD_SIZE * TRACK_EM; // ~18.7

// The tagline is not part of the lockup. It takes the page's own hierarchy:
// the same weight and colour as the wordmark, told apart by size alone
// (the hero runs a 64px wordmark over a 32px tagline).
const TAG_SIZE = Math.round(WORD_SIZE / 2);

// Where the cap line sits inside a lineHeight:1 box, as a fraction of the
// font-size. Satori centres the font's content area (ascent 1.015 + descent
// 0.315 = 1.33em) on the 1em line, so the ascender pokes 0.165em out of the top
// and the cap line is 1.015 - 0.7 - 0.165 = 0.15em down from the box top. The
// baseline is then 0.15em above the box bottom, by the same symmetry.
const CAP_INSET = 0.15;

// Gaps between the flex items. The lockup's gap is ink to ink, which flexbox
// has no way to address, so these are the box margins that reproduce it:
// from the mark box's bottom edge (19.35 units below its ink) to the word box
// top (CAP_INSET above its cap line).
const WORD_GAP = Math.round(
  (GRID.capGap - GRID.inkBottom) * UNIT - CAP_INSET * WORD_SIZE,
); // ~74
// Wordmark baseline to tagline cap line: half the lockup's own mark-to-word
// gap, so the tagline reads as a caption to the lockup rather than a third
// member of it.
const TAG_GAP = Math.round(
  (GRID.capGap / 2) * UNIT - CAP_INSET * WORD_SIZE - CAP_INSET * TAG_SIZE,
); // ~33

// Centring the BOXES leaves the ink low: the mark box has 21.25 units of empty
// glow above its ink, while the tagline's descenders (y, g) fill the bottom of
// its box. Padding under the stack by that top margin lifts the visible card
// back onto centre.
const OPTICAL_LIFT = Math.round(GRID.inkTop * UNIT); // ~23

// The lockup centres the wordmark under the CORE, and v2's mark file is
// cropped to its art, so the core is not the box centre: it sits 7 units left
// of it. flex centres the box, so push the box right by that much (a margin
// on one side moves a centred item by half of it).
const CORE_SHIFT = (GRID.boxLeft + GRID.box / 2 - 128) * UNIT; // ~7.6

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
    // Fail the build loudly. A card that silently loses its faces or its
    // background still deploys, and nobody sees it until it is in a feed.
    throw new Error(`og.png: cannot read ${path}`, { cause });
  }
}

const dataUri = (mime: string, ...parts: string[]) =>
  `data:${mime};base64,${asset(...parts).toString('base64')}`;

const FONTS = join(REPO, 'assets', 'fonts', 'Host_Grotesk', 'static');
// Bold only: the wordmark is Bold by brand commitment and the tagline takes
// the page's hierarchy, which tells the two apart by size rather than weight.
const bold = asset(FONTS, 'HostGrotesk-Bold.ttf');
const mark = dataUri('image/png', REPO, 'assets', 'brand', 'png', 'pulsar-mark-1024.png');
const silk = dataUri('image/jpeg', SITE, 'assets-static', 'silk-still-dark.jpg');

/** Satori takes React-shaped nodes; this is the whole of what it needs. */
type Node = { type: string; props: Record<string, unknown> };
const h = (type: string, props: Record<string, unknown>, ...children: unknown[]): Node => ({
  type,
  props: { ...props, ...(children.length ? { children } : {}) },
});

const card: Node = h(
  'div',
  {
    style: {
      width: W,
      height: H,
      display: 'flex',
      position: 'relative',
      backgroundColor: INK,
    },
  },
  h('img', {
    src: silk,
    width: W,
    height: H,
    style: { position: 'absolute', top: 0, left: 0, objectFit: 'cover' },
  }),
  h(
    'div',
    {
      style: {
        position: 'absolute',
        top: 0,
        left: 0,
        width: W,
        height: H,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        paddingBottom: OPTICAL_LIFT,
      },
    },
    h('img', {
      src: mark,
      width: MARK_SIZE,
      height: MARK_SIZE,
      style: { marginLeft: 2 * CORE_SHIFT },
    }),
    h(
      'div',
      {
        style: {
          display: 'flex',
          fontFamily: 'Host Grotesk',
          fontWeight: 700,
          fontSize: WORD_SIZE,
          lineHeight: 1,
          letterSpacing: TRACKING,
          color: STAR,
          marginTop: WORD_GAP,
          // Letter-spacing trails the final R, so a centred box sits half a
          // tracking unit left of true centre. The negative margin takes that
          // trailing space back out of the box: the authored lockup centres
          // the wordmark's INK under the core.
          marginRight: -TRACKING,
        },
      },
      'PULSAR',
    ),
    h(
      'div',
      {
        style: {
          display: 'flex',
          fontFamily: 'Host Grotesk',
          fontWeight: 700,
          fontSize: TAG_SIZE,
          lineHeight: 1,
          color: STAR,
          marginTop: TAG_GAP,
        },
      },
      TAGLINE,
    ),
  ),
);

export const GET = async (): Promise<Response> => {
  const svg = await satori(card as never, {
    width: W,
    height: H,
    fonts: [{ name: 'Host Grotesk', data: bold, weight: 700, style: 'normal' }],
  });

  // resvg rasterises, sharp encodes. resvg only emits PNG, which is the wrong
  // container for a photographic ground -- the same card costs ~541KB as a
  // PNG and ~45KB as a JPEG, and quantising the PNG is not a way out of it
  // (256 colours still runs 261KB and bands the nebula). Nothing is asked of
  // sharp but the encode, so the pixels are still resvg's.
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: W } }).render().asPng();

  const jpeg = await sharp(png)
    .flatten({ background: INK }) // the card has no transparency to keep
    .jpeg({ quality: 86, progressive: true, mozjpeg: true })
    .toBuffer();

  return new Response(new Uint8Array(jpeg), {
    headers: { 'content-type': 'image/jpeg' },
  });
};
