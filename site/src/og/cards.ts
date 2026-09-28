// The share cards, one per page, as data.
//
// Base.astro looks a page's card up here by its route and emits the og:image
// tags from it; src/pages/og/[card].jpg.ts renders every entry at build time.
// Both read this one list, so a page cannot name a card that is never drawn,
// and a card cannot be drawn with copy that disagrees with its tags.
//
// Adding a page means adding a card: Base.astro throws on a route with no
// entry here, which fails the build rather than shipping a page that shares
// with the wrong picture.
//
// Copy rules for a card: the headline is the page's own promise in a few
// words, set large enough to read at 300px wide; the visual is something the
// page actually shows (a real command, a real screenshot, the real build), never
// an illustration of a claim.
import { changelog, version } from '../data/build';
import { IMAGES } from '../data/site';

/** A line of a terminal visual: a command after a prompt, with an optional comment beside it. */
export type Line = { cmd: string; note?: string };

export type Visual =
  /** Three real desktop screenshots, from site/assets-static/themes. */
  | { kind: 'desktops'; themes: { slug: string; variant: 'dark' | 'light' }[] }
  /** A dark code block, the way the page's own arc-code-block draws one. */
  | { kind: 'terminal'; lines: Line[]; icon?: string }
  /** The latest build, from the build data the changelog page renders. */
  | { kind: 'build' };

export interface Card {
  /** file name under /og/, and the route it belongs to */
  slug: string;
  path: string;
  headline: string;
  /** a short second line under the headline; optional */
  sub?: string;
  /** og:image:alt, describing the picture rather than repeating the page */
  alt: string;
  visual: Visual;
}

// "2026-09-26T03:00:09Z" -> "September 26, 2026". UTC and spelled out, so the
// card reads the same wherever the build runs and whoever reads it.
const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
function longDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) throw new Error(`og cards: unreadable build date ${iso}`);
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()}`;
}

export const buildDate = longDate(changelog.generated);
export { version };

const HOME_THEMES: { slug: string; variant: 'dark' | 'light' }[] = [
  { slug: 'gruvbox', variant: 'dark' },
  { slug: 'catppuccin', variant: 'light' },
  { slug: 'pulsar', variant: 'dark' },
];

export const CARDS: Card[] = [
  {
    slug: 'home',
    path: '/',
    headline: 'Your lighthouse in the sky.',
    sub: 'A stylish, atomic, agentic Linux.',
    alt: 'The Pulsar logo beside three screenshots of the same desktop in the Gruvbox, Catppuccin and Pulsar themes, with the line: your lighthouse in the sky.',
    visual: { kind: 'desktops', themes: HOME_THEMES },
  },
  {
    slug: 'install',
    path: '/docs/install',
    headline: 'Install it fresh, or switch in place.',
    sub: 'A free ISO, or one command from any atomic Fedora.',
    alt: `The Pulsar logo and the switch command in a dark terminal: sudo bootc switch ${IMAGES.vanilla}:latest.`,
    visual: {
      kind: 'terminal',
      lines: [{ cmd: `sudo bootc switch ${IMAGES.vanilla}:latest` }, { cmd: 'sudo systemctl reboot' }],
    },
  },
  {
    slug: 'cli',
    path: '/docs/cli',
    headline: 'One command for the whole system.',
    alt: 'The Pulsar logo and three pulsar commands in a dark terminal: theme set, doctor and rollback.',
    visual: {
      kind: 'terminal',
      // Each comment says what the CLI's own help text says for that command,
      // in few enough words to stay readable at thumbnail size.
      lines: [
        { cmd: 'pulsar theme set tokyo-night', note: 'recolor everything' },
        { cmd: 'pulsar doctor', note: 'is it healthy?' },
        { cmd: 'sudo pulsar rollback', note: 'undo an update' },
      ],
    },
  },
  {
    slug: 'gamescale',
    path: '/docs/gamescale',
    headline: 'Your screen’s real resolution, for one game.',
    alt: 'The Pulsar logo, the gamescale icon, and the command that sets gamescale up for Steam in a dark terminal.',
    visual: {
      kind: 'terminal',
      icon: 'gamescale',
      lines: [{ cmd: 'pulsar setup gamescale --platform steam' }],
    },
  },
  {
    slug: 'provenance',
    path: '/docs/provenance',
    headline: 'Every image has a paper trail.',
    sub: 'Full package list attached, diffed every night.',
    alt: `The Pulsar logo and the command that lists the package list attached to the image: oras discover ${IMAGES.vanilla}:latest.`,
    visual: {
      kind: 'terminal',
      lines: [{ cmd: `oras discover ${IMAGES.vanilla}:latest` }],
    },
  },
  {
    slug: 'changelog',
    path: '/docs/changelog',
    headline: 'What changed last night.',
    alt: `The Pulsar logo and the latest build, ${version}, built ${buildDate}, with its package counts.`,
    visual: { kind: 'build' },
  },
  {
    slug: 'agents',
    path: '/docs/agents-safety',
    headline: 'The safest machine to hand an agent.',
    sub: 'It can help with anything. It can’t break the system.',
    alt: 'The Pulsar logo and two commands in a dark terminal: pulsar agent sandbox on and pulsar agent guard on.',
    visual: {
      kind: 'terminal',
      lines: [
        { cmd: 'pulsar agent sandbox on', note: 'one project, no keys' },
        { cmd: 'pulsar agent guard on', note: 'installs ask first' },
      ],
    },
  },
  {
    slug: 'themes',
    path: '/docs/theming',
    headline: 'Sixteen themes, one command.',
    sub: 'The whole desktop changes together, and back.',
    alt: 'The Pulsar logo and three pulsar theme commands in a dark terminal: list, set catppuccin and revert.',
    visual: {
      kind: 'terminal',
      lines: [
        { cmd: 'pulsar theme list', note: 'all sixteen' },
        { cmd: 'pulsar theme set catppuccin', note: 'the whole desktop' },
        { cmd: 'pulsar theme revert', note: 'stock GNOME, exactly' },
      ],
    },
  },
  {
    slug: 'docs',
    path: '/docs',
    headline: 'How Pulsar works',
    sub: 'Install, themes, agents, and how every image is built and signed.',
    alt: 'A dark code block with pulsar agent guide and pulsar doctor, the commands the docs start from.',
    visual: {
      kind: 'terminal',
      lines: [{ cmd: 'pulsar agent guide', note: 'how this machine works' }, { cmd: 'pulsar doctor', note: 'is it all healthy?' }],
    },
  },
];

/** The card for a route. Throws, so a page without one fails the build. A
    page under /docs without a card of its own shares the docs card. */
export function cardFor(path: string): Card {
  const trimmed = path.length > 1 ? path.replace(/\/+$/, '') : path;
  const card =
    CARDS.find((c) => c.path === trimmed) ??
    (trimmed.startsWith('/docs/') ? CARDS.find((c) => c.path === '/docs') : undefined);
  if (!card) {
    throw new Error(
      `og: no share card for route "${path}". Add one to site/src/og/cards.ts.`,
    );
  }
  return card;
}

/** Where a card is served from, relative to the site root. */
export const cardUrl = (card: Card) => `/og/${card.slug}.jpg`;
