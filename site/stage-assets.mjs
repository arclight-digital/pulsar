// Stage the shared brand assets into site/public/assets before Astro builds.
//
// The page and the OS must not be able to drift apart, so every mark, font and
// still the page serves is copied from the repo's assets/ at build time rather
// than kept as a second copy under site/. public/assets is gitignored for the
// same reason: if it is in git, someone will edit it there.
//
// These land in public/ rather than being imported through Vite on purpose --
// their URLs have to be stable. og:image is an absolute URL in a share card
// that outlives the deploy, and a content hash would change it on every build.
//
// The wallpaper shader is NOT staged: src/scripts/sky.ts imports
// assets/shaders/pulsar.frag directly with ?raw, so it is compiled into the
// bundle from the same file the OS wallpapers are rendered from.
//
// Runs from `npm run stage`, which `npm run dev` and `npm run build` both
// depend on. Node only -- Cloudflare's builder has node and nothing else.
import { cp, mkdir, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = dirname(fileURLToPath(import.meta.url));
const REPO = join(SITE, '..');
const OUT = join(SITE, 'public', 'assets');

// [source relative to the repo root, name it is served as]
const FILES = [
  // brand: the hero/footer marks in both cuts, plus the favicon
  ['assets/brand/pulsar-mark.svg', 'pulsar-mark.svg'],
  ['assets/brand/pulsar-mark-color-dark.svg', 'pulsar-mark-color-dark.svg'],
  ['assets/brand/pulsar-animated.svg', 'pulsar-animated.svg'],
  ['assets/brand/pulsar-animated-color-dark.svg', 'pulsar-animated-color-dark.svg'],
  ['assets/brand/favicon.svg', 'favicon.svg'],

  // the two faces the page sets itself in
  ['assets/fonts/Host_Grotesk/static/HostGrotesk-Regular.ttf', 'HostGrotesk-Regular.ttf'],
  ['assets/fonts/Host_Grotesk/static/HostGrotesk-Bold.ttf', 'HostGrotesk-Bold.ttf'],
  ['assets/fonts/JetBrains_Mono/static/JetBrainsMono-Regular.ttf', 'JetBrainsMono-Regular.ttf'],

  // both licenses travel with their fonts -- the OFL requires it, and the two
  // files have the same name at the source, so they are renamed apart here
  ['assets/fonts/Host_Grotesk/OFL.txt', 'OFL-host-grotesk.txt'],
  ['assets/fonts/JetBrains_Mono/OFL.txt', 'OFL-jetbrains-mono.txt'],

  // Committed stills: the no-WebGL and still-loading hero ground, the gamescale
  // icon, and the share card. The one place rendered output lives in git --
  // silk is locked, the set is ~230KB, and re-rendering is documented beside
  // the files.
  ['site/assets-static/silk-still-dark.jpg', 'silk-still-dark.jpg'],
  ['site/assets-static/silk-still-light.jpg', 'silk-still-light.jpg'],
  ['site/assets-static/gamescale.svg', 'gamescale.svg'],
  ['site/assets-static/og.jpg', 'og.jpg'],
];

// Clear first: a file dropped from the list above must leave the deploy too,
// or a stale asset outlives the markup that referenced it.
await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });

await Promise.all(
  FILES.map(([from, name]) =>
    cp(join(REPO, from), join(OUT, name)).catch((cause) => {
      // A missing source is fatal. The page would otherwise deploy with a
      // broken mark or an unstyled face and nothing would say so.
      throw new Error(`cannot stage ${from}: ${cause.message}`, { cause });
    }),
  ),
);

console.log(`staged ${FILES.length} assets into public/assets`);
