// The URLs and registry names the page repeats. Written once so a rename
// cannot leave half the page pointing at the old thing.
export const REPO = 'https://github.com/arclight-digital/pulsar';

// The site's own origin, and the only place in site/ that spells it.
// astro.config.mjs hands it to Astro as `site`, and everything else -- the
// canonical tags, og:url, the JSON-LD ids, the sitemap and robots.txt -- is
// built from Astro.site or from the ids below, never retyped.
//
// The site lives at getpulsar.dev (moved 2026-09-26); this line is the whole
// of the domain inside site/. Outside it, the same move touched: the Worker's
// custom domain and a 301 from pulsar.arclight.digital/* (Cloudflare),
// BUILDD_SITE_ORIGIN on helios (the beacon's CORS origin, or the live-build
// chip goes quiet), and Containerfile's PULSAR_CHANGELOG_URL. rpm-sbom.sh's
// SPDX documentNamespace still names the old host on purpose: it is an
// identifier, not a URL anything fetches.
export const SITE = 'https://getpulsar.dev';

// JSON-LD node ids. Base.astro defines the nodes; pages point at them with
// { '@id': ... } rather than repeating the objects.
export const APP_ID = `${SITE}/#pulsar`;
export const ORG_ID = `${SITE}/#arclight`;

export const IMAGES = {
  vanilla: 'ghcr.io/arclight-digital/pulsar',
  nvidia: 'ghcr.io/arclight-digital/pulsar-nvidia',
} as const;

// buildd's public API on helios. The page renders from the committed manifest
// and then asks this what the registry actually holds, so a nightly that ran
// without a site publish is visible instead of invisible. CORS is locked to
// one origin (BUILDD_SITE_ORIGIN on helios), so this fetch fails on a dev
// server by design -- src/scripts/beacon.ts treats that as "say nothing".
export const BEACON = 'https://beacon.arclight.digital';

// The R2 bucket the weekly ISO build uploads to, behind its public custom
// domain. The -latest names are stable keys the build rewrites weekly; the
// dated originals stay in the bucket untouched.
export const ISO_BASE = 'https://lighthouse.arclight.digital/pulsar/iso';

export const ISOS = {
  vanilla: 'pulsar-latest-x86_64.iso',
  nvidia: 'pulsar-nvidia-latest-x86_64.iso',
} as const;

// The public half of the release key that signs each ISO's checksum
// manifest. The private half never leaves the signing host; this public copy
// is also committed to the repo as keys/cosign.pub, and the build verifies
// every signature against the committed copy before publishing.
export const COSIGN_PUB = `${ISO_BASE}/cosign.pub`;

// Where "Support Pulsar" points. Pulsar is free to download; this is the tip
// jar, run on Open Collective and hosted by Arclight Digital LLC. Tips are
// that company's income, not a charitable gift, so the page says "support",
// never "donate" or anything about tax.
// TODO(support): set this once the collective exists. Until then the footer
// shows the line without a link rather than guess at a URL someone else may
// own.
export const SUPPORT_URL: string | null = null;
