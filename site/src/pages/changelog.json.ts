// The full package diff, republished at /changelog.json exactly as the nightly
// committed it. The page renders a capped list; this is the whole thing, and
// the hint under the changelog section links straight to it.
//
// Served from the source file byte for byte (?raw, not a re-serialised import)
// so what a reader downloads is what the build host wrote.
import raw from '../data/changelog.json?raw';

export const GET = (): Response =>
  new Response(raw, {
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
