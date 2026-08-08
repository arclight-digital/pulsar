// The URLs and registry names the page repeats. Written once so a rename
// cannot leave half the page pointing at the old thing.
export const REPO = 'https://github.com/arclight-digital/pulsar';

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
