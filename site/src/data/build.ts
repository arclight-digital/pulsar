// What the nightly published, as the page reads it.
//
// changelog.json and manifest.json in this directory are written by
// scripts/publish.sh on the build host: the changelog is diffed from the SBOMs
// attached to the two images, and the manifest is extracted from the nvidia
// image's own baked /usr/share/pulsar/manifest.json -- the same file
// `pulsar manifest` prints on the machine. Neither is written by hand, and
// neither should ever be edited here.
//
// The commit that lands them wakes Cloudflare's git integration, which runs
// this build. That is the whole hookup: the site cannot say something the
// registry does not, because it is rendered from what was pushed to it.
//
// The types are declared rather than inferred. A quiet night ships empty
// arrays, and TypeScript would infer those as never[] -- so the day a package
// finally changed, every field on the row would be a type error.
import changelogJson from './changelog.json';
import manifestJson from './manifest.json';

export interface ImageRef {
  ref: string;
  digest: string;
}

/** A package that exists on one side of the diff only. */
export interface PackageEntry {
  name: string;
  version: string;
}

/** A package that exists on both sides at different versions. */
export interface PackageChange {
  name: string;
  from: string;
  to: string;
  direction?: 'upgraded' | 'downgraded' | string;
}

export interface Changelog {
  generated: string;
  /** true on the very first build, when there is nothing to diff against */
  baseline?: boolean;
  from?: ImageRef;
  to?: ImageRef;
  summary: {
    added: number;
    removed: number;
    upgraded: number;
    downgraded: number;
    changed: number;
  };
  added: PackageEntry[];
  removed: PackageEntry[];
  changed: PackageChange[];
}

export interface Manifest {
  image: string;
  variant?: string;
  version: string;
  base: string;
  built: string;
  kernel: string;
  components: Record<string, string>;
  /** present in the file, deliberately not shown -- see Manifest.astro */
  changelog_url?: string;
  attestation?: string;
  nvidia_driver?: string;
}

export const changelog = changelogJson as Changelog;
export const manifest = manifestJson as Manifest;

/** The build the whole page names: the hero chip, the manifest card, the diff. */
export const version = manifest.version || 'nightly';
