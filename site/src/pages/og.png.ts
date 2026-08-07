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
// and it is rebuilt on every deploy. There is nothing left to keep in sync.
//
// The background is the committed silk still rather than a live shader render:
// resvg cannot run WebGL, and the still is itself an output of that same
// shader, so the card and the hero are still showing the same field.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Resvg } from '@resvg/resvg-js';
import satori from 'satori';

export const prerender = true;

const W = 1200;
const H = 630; // the Open Graph standard size

const STAR = '#E9EDF7';
const INK = '#0B0E1A';
const TAGLINE = 'Your lighthouse in the sky.';

// Proportions taken from the authored lockup, assets/brand/pulsar-lockup-stacked.svg,
// which is a 234x253 canvas holding:
//
//   mark      160 square, top at y=16, so its bottom edge is y=176
//   wordmark  font-size 34, font-weight 700, letter-spacing 6.8, baseline y=207
//
// Everything below is those numbers as ratios, so the card is a rendering of
// the lockup at card scale rather than a second set of hand-tuned values that
// can disagree with it.
const LOCKUP = {
  wordPerMark: 34 / 160, // 0.2125
  trackPerWord: 6.8 / 34, // 0.2em, the brand's tracking
  baselineBelowMarkPerMark: (207 - 176) / 160, // 0.19375
};

const MARK_SIZE = 280;
const WORD_SIZE = Math.round(MARK_SIZE * LOCKUP.wordPerMark); // 60
const TRACKING = WORD_SIZE * LOCKUP.trackPerWord; // 12

// The tagline is not part of the lockup. It takes the page's own hierarchy:
// the same weight and colour as the wordmark, told apart by size alone
// (the hero runs a 64px wordmark over a 32px tagline).
const TAG_SIZE = Math.round(WORD_SIZE / 2);

// Gaps between the flex items. The lockup expresses its gap as a baseline
// offset, which flexbox has no way to address, so these are the box margins
// that reproduce it. Measured back off the rendered pixels rather than
// assumed: they put the wordmark's cap top 0.248 of a mark box below the
// mark's ink, against the authored lockup's 0.239.
const WORD_GAP = 6;
const TAG_GAP = 18;

// The mark's artwork does not fill its own box -- pulsar-mark-1024.png has
// transparent margin, and its ink runs from 0.106 to 0.802 of the height, so
// there is roughly twice as much dead space below the arc as above it.
// Centring the BOXES therefore leaves the INK sitting low. Half the imbalance,
// as padding under the stack, lifts the visible card back onto centre.
const OPTICAL_LIFT = Math.round(MARK_SIZE * (1 - 0.802 - 0.106)); // ~26px

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
const mark = dataUri('image/png', REPO, 'assets', 'brand', 'pulsar-mark-1024.png');
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
    h('img', { src: mark, width: MARK_SIZE, height: MARK_SIZE }),
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
          // trailing space back out of the box, which is the same optical
          // recentre the authored lockup makes by anchoring at 120.4 rather
          // than the mark's 117.
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

  const png = new Resvg(svg, { fitTo: { mode: 'width', value: W } }).render().asPng();

  return new Response(new Uint8Array(png), {
    headers: { 'content-type': 'image/png' },
  });
};
