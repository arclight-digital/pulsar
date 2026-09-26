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
  | { kind: 'terminal'; label: string; lines: Line[]; icon?: string }
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

// "2026-09-26T03:00:09Z" -> "26 September 2026". UTC and spelled out, so the
// card reads the same wherever the build runs and whoever reads it.
const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
function longDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) throw new Error(`og cards: unreadable build date ${iso}`);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
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
    headline: 'An agentic, atomic, stylish Linux.',
    sub: 'Sixteen desktop themes in one command.',
    alt: 'The Pulsar logo beside three screenshots of the same desktop in the Gruvbox, Catppuccin and Pulsar themes, with the line: an agentic, atomic, stylish Linux.',
    visual: { kind: 'desktops', themes: HOME_THEMES },
  },
  {
    slug: 'install',
    path: '/install',
    headline: 'One command, one reboot.',
    sub: 'Already on Fedora Silverblue? Switch in place.',
    alt: `The Pulsar logo and the install command in a dark terminal: sudo bootc switch ${IMAGES.vanilla}:latest.`,
    visual: {
      kind: 'terminal',
      label: 'bash',
      lines: [{ cmd: `sudo bootc switch ${IMAGES.vanilla}:latest` }, { cmd: 'sudo systemctl reboot' }],
    },
  },
  {
    slug: 'cli',
    path: '/cli',
    headline: 'One command for the whole system.',
    alt: 'The Pulsar logo and three pulsar commands in a dark terminal: theme set, doctor and rollback.',
    visual: {
      kind: 'terminal',
      label: 'bash',
      // Each comment is the CLI's own help text for that command (cli.astro's
      // USAGE, which is verbatim from cli/pulsar), trimmed to fit.
      lines: [
        { cmd: 'pulsar theme set tokyo-night', note: 're-colour the whole desktop' },
        { cmd: 'pulsar doctor', note: 'health snapshot' },
        { cmd: 'sudo pulsar rollback', note: 'boot the previous deployment' },
      ],
    },
  },
  {
    slug: 'gamescale',
    path: '/gamescale',
    headline: 'Your screen’s real resolution, for one game.',
    alt: 'The Pulsar logo, the gamescale icon, and the command that sets gamescale up for Steam in a dark terminal.',
    visual: {
      kind: 'terminal',
      label: 'bash',
      icon: 'gamescale',
      lines: [{ cmd: 'pulsar setup gamescale --platform steam' }],
    },
  },
  {
    slug: 'provenance',
    path: '/provenance',
    headline: 'Every image has a paper trail.',
    sub: 'Full package list attached, diffed every night.',
    alt: `The Pulsar logo and the command that lists the package list attached to the image: oras discover ${IMAGES.vanilla}:latest.`,
    visual: {
      kind: 'terminal',
      label: 'bash',
      lines: [{ cmd: `oras discover ${IMAGES.vanilla}:latest` }],
    },
  },
  {
    slug: 'changelog',
    path: '/changelog',
    headline: 'What changed last night.',
    alt: `The Pulsar logo and the latest build, ${version}, built ${buildDate}, with its package counts.`,
    visual: { kind: 'build' },
  },
];

/** The card for a route. Throws, so a page without one fails the build. */
export function cardFor(path: string): Card {
  const norm = path.length > 1 ? path.replace(/\/+$/, '') : path;
  const card = CARDS.find((c) => c.path === norm);
  if (!card) {
    throw new Error(
      `og: no share card for route "${path}". Add one to site/src/og/cards.ts.`,
    );
  }
  return card;
}

/** Where a card is served from, relative to the site root. */
export const cardUrl = (card: Card) => `/og/${card.slug}.jpg`;
