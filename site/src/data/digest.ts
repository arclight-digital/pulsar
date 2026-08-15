// The night's diff, turned into something a person can read in one look.
//
// scripts/sbom-changelog.sh produces the truth: one row per package name that
// moved between the two SBOMs. That is the right shape for a diff and the
// wrong shape for a page. A kernel bump is seventeen rows -- kernel,
// kernel-core, kernel-devel, kernel-modules{,-core,-extra}, kernel-tools{,-libs},
// perf, python3-perf -- and a night where Fedora rebuilt three packages against
// a new dependency, changing nothing upstream, looks exactly as loud as a night
// where Firefox moved two versions. The section swung between rendering nothing
// at all and rendering forty-six identical-looking rows, and neither told you
// what happened.
//
// Everything here is DERIVED, not written: the rules run at build time over the
// committed changelog.json, they are deterministic, and /changelog.json still
// serves the untouched diff byte for byte. The page gained a point of view
// about the data; it did not gain a hand-maintained release note that can
// disagree with what shipped.
import { changelog, manifest } from './build';
import type { Changelog, PackageChange, PackageEntry } from './build';

// ---------------------------------------------------------------------------
// RPM versions
// ---------------------------------------------------------------------------

/** `[epoch:]version-release`, split the way RPM does: epoch to the first colon,
 *  release from the LAST hyphen, because upstream versions contain hyphens and
 *  releases do not. */
export function splitEvr(evr: string): { epoch: string; version: string; release: string } {
  let rest = evr;
  let epoch = '';
  const colon = rest.indexOf(':');
  if (colon > 0 && /^\d+$/.test(rest.slice(0, colon))) {
    epoch = rest.slice(0, colon);
    rest = rest.slice(colon + 1);
  }
  const dash = rest.lastIndexOf('-');
  return dash < 0
    ? { epoch, version: rest, release: '' }
    : { epoch, version: rest.slice(0, dash), release: rest.slice(dash + 1) };
}

/** How far a transition reached. `rebuild` is the load-bearing one: same
 *  upstream version, new package release -- Fedora rebuilding against a changed
 *  dependency, an SRPM fix, a mass rebuild. Real, worth publishing, and not
 *  news in the way a version bump is. Separating those two is most of what
 *  makes a busy night legible.
 *
 *  major/minor/patch are POSITIONAL -- the index of the first segment that
 *  differs -- not a claim about semver, which most of Fedora does not follow.
 *  They rank rows; only `major` is ever labelled in the page. */
export type Reach = 'major' | 'minor' | 'patch' | 'epoch' | 'rebuild';

export function reachOf(from: string, to: string): Reach {
  const a = splitEvr(from);
  const b = splitEvr(to);
  if (a.version === b.version) return a.epoch === b.epoch ? 'rebuild' : 'epoch';
  const av = a.version.split(/[._\-~^+]/);
  const bv = b.version.split(/[._\-~^+]/);
  let i = 0;
  while (i < Math.max(av.length, bv.length) && av[i] === bv[i]) i++;
  return i === 0 ? 'major' : i === 1 ? 'minor' : 'patch';
}

/** A version transition split into the parts that stayed and the part that
 *  moved, so the page can push the former back and light the latter. Both
 *  sides are still printed in full -- see Version.astro for why.
 *
 *  Tokenised on separators rather than characters, so a shared boundary is
 *  never split mid-number: `7.1.7-200` -> `7.1.8-200` moves `7` to `8`, not
 *  `7-` to `8-`. */
export interface VersionDelta {
  head: string;
  fromMid: string;
  toMid: string;
  tail: string;
}

export function versionDelta(from: string, to: string): VersionDelta {
  const tokens = (s: string) => s.match(/[0-9A-Za-z]+|[^0-9A-Za-z]+/g) ?? [s];
  const a = tokens(from);
  const b = tokens(to);

  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) head++;
  let tail = 0;
  while (
    tail < a.length - head &&
    tail < b.length - head &&
    a[a.length - 1 - tail] === b[b.length - 1 - tail]
  )
    tail++;

  return {
    head: a.slice(0, head).join(''),
    fromMid: a.slice(head, a.length - tail).join(''),
    toMid: b.slice(head, b.length - tail).join(''),
    tail: a.slice(a.length - tail).join(''),
  };
}

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

/** Packages that made the identical move, collapsed to one row.
 *
 *  Bucketed on the exact (from, to) pair -- NOT on a guess at the source
 *  package, which the SPDX SBOM does not carry. That keeps the row honest
 *  under its own description: every member of a group really did go from this
 *  version to that one. Two unrelated packages that coincidentally share a
 *  transition land in the same row, and the row is still true; the members are
 *  listed, so nothing is hidden by the collapse. */
export interface TransitionGroup {
  /** the member name that reads as the family's name */
  label: string;
  members: string[];
  from: string;
  to: string;
  delta: VersionDelta;
  reach: Reach;
  /** named by the image's own manifest -- the components Pulsar is defined by */
  declared: boolean;
  downgraded: boolean;
}

/** The leading hyphen-separated tokens every name in the group shares.
 *  `mesa-libGL`, `mesa-libEGL`, `mesa-dri-drivers` -> `mesa`. */
function sharedPrefix(names: string[]): string {
  const parts = names.map((name) => name.split('-'));
  const shared: string[] = [];
  for (let i = 0; i < parts[0].length; i++) {
    const token = parts[0][i];
    if (!parts.every((part) => part[i] === token)) break;
    shared.push(token);
  }
  // The whole of every name is not a prefix of the group, it IS the group.
  return shared.length === parts[0].length ? '' : shared.join('-');
}

/** What to call a group of packages that all made the same move.
 *
 *  Every rule below is here because a real night broke the one above it. The
 *  order matters and the fallbacks are deliberate: a label is the first thing
 *  read on the row, and picking it by an accident of sort order is how a
 *  kernel bump ends up headlined as `perf`. */
function labelFor(names: string[], declared: string[]): string {
  const sorted = [...names].sort();
  const matchesManifest = (name: string) => {
    const lower = name.toLowerCase();
    return declared.some((token) => lower === token || lower.startsWith(`${token}-`));
  };

  // 1. A member that names the family outright: `kernel` over
  //    `kernel-modules-extra`, `gnome-shell` over `gnome-shell-common`.
  let family = '';
  let familyScore = 1;
  for (const name of sorted) {
    const score = sorted.filter((other) => other === name || other.startsWith(`${name}-`)).length;
    if (score > familyScore) {
      family = name;
      familyScore = score;
    }
  }
  if (family) return family;

  // 2. No member names it, but the image's manifest does. Six mesa
  //    subpackages with no bare `mesa` among them are still mesa; two
  //    python3-boto packages are not "python3", which is why this needs the
  //    manifest to vouch for the prefix rather than trusting any prefix.
  const shared = sharedPrefix(sorted);
  if (shared && declared.includes(shared.toLowerCase())) return shared;

  // 3. Otherwise the member the manifest names, so a kernel bump that reaches
  //    this image as `kernel-devel` and `perf` is labelled by the kernel.
  const named = sorted.find(matchesManifest);
  if (named) return named;

  // 4. Shortest, then alphabetical -- stable across builds, and never the
  //    order the diff happened to be written in.
  return sorted.reduce((best, name) => (name.length < best.length ? name : best));
}

/** The component names the image publishes about itself, from the manifest the
 *  build baked into it -- kernel, mesa, gamescope, gamemode, mangohud,
 *  gamescale, the scheduler, the NVIDIA driver. A change to one of these is
 *  the night's news by Pulsar's own definition of what Pulsar is, which is the
 *  only definition on hand that nobody typed into this file.
 *
 *  Keys only. The manifest's VALUES are versions (`3.16.25-1.fc44`) and
 *  occasionally statuses (`scheduler_btf: malformed`), and a status is not a
 *  package name -- matching on those would be matching on noise. */
function declaredNames(): string[] {
  return [
    'kernel',
    ...Object.keys(manifest.components ?? {}),
    ...(manifest.nvidia_driver ? ['nvidia'] : []),
  ]
    .map((value) => value.toLowerCase().replace(/_/g, '-'))
    .filter((value) => /^[a-z][a-z-]{2,}$/.test(value));
}

function isDeclared(names: string[], declared: string[]): boolean {
  return names.some((name) => {
    const lower = name.toLowerCase();
    return declared.some((token) => lower === token || lower.startsWith(`${token}-`));
  });
}

const REACH_RANK: Record<Reach, number> = { major: 0, epoch: 1, minor: 2, patch: 3, rebuild: 4 };

function groupChanges(changed: PackageChange[]): TransitionGroup[] {
  const declared = declaredNames();
  const buckets = new Map<string, PackageChange[]>();
  for (const change of changed) {
    const key = `${change.from} ${change.to}`;
    const bucket = buckets.get(key);
    if (bucket) bucket.push(change);
    else buckets.set(key, [change]);
  }

  return [...buckets.values()].map((members) => {
    const names = members.map((member) => member.name).sort();
    const { from, to } = members[0];
    return {
      label: labelFor(names, declared),
      members: names,
      from,
      to,
      delta: versionDelta(from, to),
      reach: reachOf(from, to),
      declared: isDeclared(names, declared),
      // The diff decides this with rpmdev-vercmp, which knows about epochs and
      // tildes; nothing here second-guesses it.
      downgraded: members.some((member) => member.direction === 'downgraded'),
    };
  });
}

// ---------------------------------------------------------------------------
// The night
// ---------------------------------------------------------------------------

export interface Band {
  id: string;
  title: string;
  note?: string;
  groups: TransitionGroup[];
}

export interface Digest {
  /** nothing on the other side of the diff yet */
  baseline: boolean;
  /** a real diff that found nothing -- the good outcome, and its own design */
  quiet: boolean;
  /** the one fact the section leads with, or null on a quiet night */
  lead: TransitionGroup | null;
  /** shown outright: declared components, downgrades, everything upstream */
  bands: Band[];
  /** same upstream version, new package release -- folded away, counted */
  rebuilds: TransitionGroup[];
  added: PackageEntry[];
  removed: PackageEntry[];
  packages: number;
  transitions: number;
  upstream: number;
  /** packages inside rebuild groups -- the volume the night looks like but is not */
  rebuiltPackages: number;
  /** short digests, for the line that names what was compared */
  fromDigest: string;
  toDigest: string;
}

const short = (digest?: string) => (digest ?? '').replace(/^sha256:/, '').slice(0, 12);

export function buildDigest(source: Changelog = changelog): Digest {
  const groups = groupChanges(source.changed ?? []);

  // Rank once, here, and let every band inherit it: declared components first,
  // then by how far the version moved, then by how many packages moved with
  // it. Alphabetical last so a night is rendered the same way twice.
  const ranked = [...groups].sort(
    (a, b) =>
      Number(b.declared) - Number(a.declared) ||
      REACH_RANK[a.reach] - REACH_RANK[b.reach] ||
      b.members.length - a.members.length ||
      a.label.localeCompare(b.label),
  );

  // The lead is the night in one line, set large. It is rendered ONCE: the
  // bands below are the rest of the story, so the headline is never also the
  // first row of a list under it.
  const lead = ranked[0] ?? null;
  const rest = ranked.slice(1);

  // A downgrade is the one thing on this page nobody should have to open a
  // disclosure to find, whatever else it is.
  const downgraded = rest.filter((group) => group.downgraded);
  const graded = rest.filter((group) => !group.downgraded);
  const rebuilds = graded.filter((group) => group.reach === 'rebuild');
  const declared = graded.filter((group) => group.reach !== 'rebuild' && group.declared);
  const upstream = graded.filter((group) => group.reach !== 'rebuild' && !group.declared);

  const bands: Band[] = [
    {
      id: 'downgraded',
      title: 'Downgraded',
      note: 'a version went backwards',
      groups: downgraded,
    },
    {
      id: 'declared',
      title: 'Components the manifest names',
      note: 'the parts Pulsar is defined by',
      groups: declared,
    },
    { id: 'upstream', title: 'New upstream versions', groups: upstream },
  ].filter((band) => band.groups.length > 0);

  const added = source.added ?? [];
  const removed = source.removed ?? [];
  const packages = (source.changed ?? []).length;

  return {
    baseline: Boolean(source.baseline),
    quiet: packages === 0 && added.length === 0 && removed.length === 0,
    lead,
    bands,
    rebuilds,
    added,
    removed,
    packages,
    transitions: groups.length,
    upstream: groups.filter((group) => group.reach !== 'rebuild').length,
    rebuiltPackages: groups
      .filter((group) => group.reach === 'rebuild')
      .reduce((total, group) => total + group.members.length, 0),
    fromDigest: short(source.from?.digest),
    toDigest: short(source.to?.digest),
  };
}

/** Rows rendered inside the folded band before it starts counting instead.
 *  A Fedora mass rebuild is thousands of packages, and shipping thousands of
 *  list items in the HTML of a page that otherwise ships almost none is a real
 *  cost for something nobody scrolls. The remainder is COUNTED, never dropped
 *  silently -- a truncated list that looks complete is how a changelog starts
 *  lying about what shipped. */
export const FOLD_LIMIT = 40;

export const digest = buildDigest();
