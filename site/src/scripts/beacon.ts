// The hero chip, checked against the build host.
//
// Everything else on the page is rendered from src/data/manifest.json, which
// publish.sh commits from the image it just built. That is the right fallback
// and it is not a hardcoded string: it is the manifest of the build this page
// was rendered from, so with no JavaScript, no network, or no beacon the chip
// still names a build that genuinely exists.
//
// What it cannot know is what happened AFTER it was rendered. A nightly that
// succeeded without a site publish, or seventeen that failed in a row, both
// leave the committed manifest looking exactly like success. That gap is the
// only thing this script closes.
//
// So it never invents a version and never blanks one. It replaces the chip
// only when beacon names a successful build, and adds a note only when there
// is something true to say that the page could not otherwise say.
//
// One of those is a night that built nothing. The base gate in
// scripts/nightly.sh skips when no package in Fedora's base image has moved,
// and a skip commits nothing -- so the chip, the manifest card and a changelog
// headed "What changed last night" all go on describing the build before it,
// with nothing on the page to say why. buildd records the skip as a fact of
// its own, and only that fact is read here: a success with an empty version
// is also what a log that lost its version line looks like.
import { BEACON } from '../data/site';

/** Shape of the `nightly` half of GET /v1/status -- see buildd's h_status. */
interface Summary {
  outcome?: string | null;
  /** a success that built nothing: the base gate found no package to move */
  skipped?: boolean;
  version?: string | null;
  finished?: string | null;
}

interface Nightly {
  /** null is a real state: nothing succeeded inside the retained window. */
  last_success?: Summary | null;
  /** the newest scheduled run, whatever it did */
  last_attempt?: Summary | null;
  consecutive_failures?: number;
}

/** Whole days since an ISO timestamp, or null if it is missing or unparseable. */
function daysSince(when: string | null | undefined): number | null {
  if (!when) return null;
  const then = Date.parse(when);
  if (Number.isNaN(then)) return null;
  return Math.floor((Date.now() - then) / 86400000);
}

// One sentence, shown in the hero and over each changelog, so the places it
// appears cannot phrase the same night differently. "Base image" on purpose:
// the gate never looks at what Pulsar layers on top, and a night where only
// that moved is skipped too -- see the note above base_moved().
const SKIPPED = 'Last night’s build was skipped: no package in Fedora’s base image had moved.';

export async function initBeacon(): Promise<void> {
  const chip = document.getElementById('build-version');
  const note = document.getElementById('build-note');
  // The changelog sections, on the home page and on /changelog, which has no
  // chip at all.
  const skipNotes = document.querySelectorAll<HTMLElement>('[data-skip-note]');
  if (!(chip && note) && !skipNotes.length) return;

  let nightly: Nightly | undefined;
  try {
    const response = await fetch(`${BEACON}/v1/status`);
    if (!response.ok) return; // leave the rendered build alone
    nightly = (await response.json())?.nightly;
  } catch {
    return; // beacon unreachable, or a dev origin CORS refuses
  }
  if (!nightly) return;

  // The newest scheduled run built nothing, recently enough to be "last
  // night". An older skip with nothing after it is a pipeline that has
  // stopped, and the staleness note below says that instead.
  const attempt = nightly.last_attempt;
  const skipDays =
    attempt?.outcome === 'success' && attempt.skipped === true ? daysSince(attempt.finished) : null;
  const skipped = skipDays !== null && skipDays < 2;

  if (skipped) {
    for (const el of skipNotes) {
      el.textContent = SKIPPED;
      el.hidden = false;
    }
  }

  if (!chip || !note) return;
  // the top bar's badge names the same build; it follows the chip
  const echoes = document.querySelectorAll<HTMLElement>('[data-build-version]');

  // What the build host committed. Read before anything can overwrite it,
  // because the note may need to name it.
  const rendered = chip.textContent?.trim() ?? '';

  const lines: string[] = [];
  if (skipped) lines.push(SKIPPED);

  // Tracked apart from the note. "The chip is newer than the page" is a note
  // worth adding but not a stale pipeline -- a build that landed an hour ago
  // should still pulse. Nor is a skip: the gate ran and answered, which is the
  // pipeline doing its job.
  let stale = false;
  const success = nightly.last_success;

  if (success?.version) {
    for (const el of echoes) el.textContent = success.version;

    // The chip now names a newer build than the manifest card and the
    // changelog do. Saying so is the whole point -- an unexplained mismatch
    // between two numbers on one page is worse than either number alone.
    if (rendered && success.version !== rendered) {
      lines.push(`The manifest and changelog below describe ${rendered}, the build this page was rendered from.`);
    }
  }

  // Outside the version check, because a skip is a success with no version:
  // inside it, the most common kind of night switched this off, and a timer
  // that died after one would never read as stale.
  const days = success ? daysSince(success.finished) : null;
  if (days !== null && days >= 2) {
    lines.push(
      success?.skipped
        ? `Last successful nightly was ${days} days ago, and it had nothing to build.`
        : `Last successful build was ${days} days ago.`,
    );
    stale = true;
  }

  const failures = nightly.consecutive_failures ?? 0;
  if (failures >= 3) {
    // Without a last_success there is no "since" for these failures to be
    // since. The retained window is the honest frame instead.
    lines.push(
      success
        ? `${failures} builds have failed since.`
        : `${failures} builds have failed, and none has succeeded in the window the build host retains.`,
    );
    stale = true;
  }

  // A stale chip stops pulsing. The dot is the page's liveness cue, and a
  // beacon still sweeping over a pipeline that has not shipped in days is the
  // one thing on this page that would be decorative rather than true.
  if (stale) chip.closest('#build-chip')?.setAttribute('data-stale', '');

  if (!lines.length) return;
  note.textContent = lines.join(' ');
  note.hidden = false;
}
