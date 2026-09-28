// The docs sidebar, grouped by what you came to do. A `slug` is a repo doc
// (docs/*.md) rendered at /docs/<slug>; an `href` is a page written for the
// site, under src/pages/docs/.
export type DocLink = { label: string; slug?: string; href?: string; icon: string };
export type DocGroup = { heading: string; links: DocLink[] };

export const DOCS_NAV: DocGroup[] = [
  {
    heading: 'Start',
    links: [
      { label: 'Overview', href: '/docs', icon: 'book-open' },
      { label: 'Install', href: '/docs/install', icon: 'download-simple' },
    ],
  },
  {
    heading: 'Use',
    links: [
      { label: 'Themes', slug: 'theming', icon: 'palette' },
      { label: 'Agents and safety', slug: 'agents-safety', icon: 'robot' },
      { label: 'The pulsar command', href: '/docs/cli', icon: 'terminal-window' },
      { label: 'gamescale', href: '/docs/gamescale', icon: 'game-controller' },
    ],
  },
  {
    heading: 'Trust',
    links: [
      { label: 'Signing', slug: 'signing', icon: 'seal-check' },
      { label: 'Provenance', href: '/docs/provenance', icon: 'git-commit' },
      { label: 'Changelog', href: '/docs/changelog', icon: 'clock-counter-clockwise' },
    ],
  },
];

export const hrefOf = (l: DocLink) => l.href ?? `/docs/${l.slug}`;
