// The URLs and registry names the page repeats. Written once so a rename
// cannot leave half the page pointing at the old thing.
export const REPO = 'https://github.com/arclight-digital/pulsar';

export const IMAGES = {
  vanilla: 'ghcr.io/arclight-digital/pulsar',
  nvidia: 'ghcr.io/arclight-digital/pulsar-nvidia',
} as const;

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
