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

/** A card's command: after a prompt, with an optional comment beside it. */
export type Line = { cmd: string; note?: string };

export type Visual =
  /** Three real desktop screenshots, from site/assets-static/themes. */
  | { kind: 'desktops'; themes: { slug: string; variant: 'dark' | 'light' }[] }
  /** One real command, as the poster's small print along the bottom. */
  | { kind: 'terminal'; line: Line; icon?: string }
  /** The latest build, from the build data the changelog page renders. */
  | { kind: 'build' };

export interface Card {
  /** file name under /og/, and the route it belongs to */
  slug: string;
  path: string;
  headline: string;
  /** the headline's closing words, lit in the accent the way the site's
      .lift is; must be how the headline ends */
  lift?: string;
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
    lift: 'in the sky.',
    sub: 'A stylish, atomic, agentic Linux.',
    alt: 'The Pulsar logo beside three screenshots of the same desktop in the Gruvbox, Catppuccin and Pulsar themes, with the line: your lighthouse in the sky.',
    visual: { kind: 'desktops', themes: HOME_THEMES },
  },
  {
    slug: 'install',
    path: '/docs/install',
    headline: 'Install it fresh, or switch in place.',
    lift: 'switch in place.',
    sub: 'A free ISO, or one command from any atomic Fedora.',
    alt: `The Pulsar logo, the line "Install it fresh, or switch in place.", and the switch command: sudo bootc switch ${IMAGES.vanilla}:latest.`,
    visual: { kind: 'terminal', line: { cmd: `sudo bootc switch ${IMAGES.vanilla}:latest` } },
  },
  {
    slug: 'cli',
    path: '/docs/cli',
    headline: 'One command for the whole system.',
    lift: 'the whole system.',
    alt: 'The Pulsar logo, the line "One command for the whole system.", and the command pulsar theme set tokyo-night.',
    // the comment says what the CLI's own help text says, in few enough
    // words to read at thumbnail size
    visual: { kind: 'terminal', line: { cmd: 'pulsar theme set tokyo-night', note: 'recolor everything' } },
  },
  {
    slug: 'gamescale',
    path: '/docs/gamescale',
    headline: 'Your screen’s real resolution, for one game.',
    lift: 'for one game.',
    alt: 'The Pulsar logo, the gamescale icon, and the command that sets gamescale up for Steam.',
    visual: { kind: 'terminal', icon: 'gamescale', line: { cmd: 'pulsar setup gamescale --platform steam' } },
  },
  {
    slug: 'provenance',
    path: '/docs/provenance',
    headline: 'Every image has a paper trail.',
    lift: 'a paper trail.',
    sub: 'Full package list attached, diffed every night.',
    alt: `The Pulsar logo and the command that lists the package list attached to the image: oras discover ${IMAGES.vanilla}:latest.`,
    visual: { kind: 'terminal', line: { cmd: `oras discover ${IMAGES.vanilla}:latest` } },
  },
  {
    slug: 'changelog',
    path: '/docs/changelog',
    headline: 'What changed last night.',
    lift: 'last night.',
    alt: `The Pulsar logo and the latest build, ${version}, built ${buildDate}, with its package counts.`,
    visual: { kind: 'build' },
  },
  {
    slug: 'agents',
    path: '/docs/agents-safety',
    headline: 'The safest machine to hand an agent.',
    lift: 'hand an agent.',
    sub: 'It can help with anything. It can’t break the system.',
    alt: 'The Pulsar logo, the line "The safest machine to hand an agent.", and the command pulsar agent sandbox on.',
    visual: { kind: 'terminal', line: { cmd: 'pulsar agent sandbox on', note: 'one project, no keys' } },
  },
  {
    slug: 'themes',
    path: '/docs/theming',
    headline: 'Sixteen themes, one command.',
    lift: 'one command.',
    sub: 'The whole desktop changes together, and back.',
    alt: 'The Pulsar logo, the line "Sixteen themes, one command.", and the command pulsar theme set catppuccin.',
    visual: { kind: 'terminal', line: { cmd: 'pulsar theme set catppuccin', note: 'the whole desktop' } },
  },
  {
    slug: 'docs',
    path: '/docs',
    headline: 'How Pulsar works, top to bottom.',
    lift: 'top to bottom.',
    sub: 'Install, themes, agents, and how every image is built and signed.',
    alt: 'The Pulsar logo, the line "How Pulsar works, top to bottom.", and the command pulsar agent guide.',
    visual: { kind: 'terminal', line: { cmd: 'pulsar agent guide', note: 'how this machine works' } },
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
