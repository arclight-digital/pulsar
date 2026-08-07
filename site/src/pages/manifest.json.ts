// The shipped image's own baked manifest, republished at /manifest.json --
// the same file `pulsar manifest` reads on the machine. The manifest card
// renders it; this is the machine-readable copy, and changelog.json's
// changelog_url points readers between the two.
//
// NOT a web app manifest, despite the name. There is no <link rel="manifest">
// anywhere on the page, and adding one would point a browser at this.
import raw from '../data/manifest.json?raw';

export const GET = (): Response =>
  new Response(raw, {
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
