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
import { BEACON } from '../data/site';

/** Shape of the `nightly` half of GET /v1/status -- see buildd's h_status. */
interface Summary {
  version?: string | null;
  finished?: string | null;
}

interface Nightly {
  /** null is a real state: nothing succeeded inside the retained window. */
  last_success?: Summary | null;
  consecutive_failures?: number;
}

/** Whole days since an ISO timestamp, or null if it is missing or unparseable. */
function daysSince(when: string | null | undefined): number | null {
  if (!when) return null;
  const then = Date.parse(when);
  if (Number.isNaN(then)) return null;
  return Math.floor((Date.now() - then) / 86400000);
}

export async function initBeacon(): Promise<void> {
  const chip = document.getElementById('build-version');
  const note = document.getElementById('build-note');
  if (!chip || !note) return;

  // What the build host committed. Read before anything can overwrite it,
  // because the note may need to name it.
  const rendered = chip.textContent?.trim() ?? '';

  let nightly: Nightly | undefined;
  try {
    const response = await fetch(`${BEACON}/v1/status`);
    if (!response.ok) return; // leave the rendered build alone
    nightly = (await response.json())?.nightly;
  } catch {
    return; // beacon unreachable, or a dev origin CORS refuses
  }
  if (!nightly) return;

  const lines: string[] = [];

  // Tracked apart from the note. "The chip is newer than the page" is a note
  // worth adding but not a stale pipeline -- a build that landed an hour ago
  // should still pulse.
  let stale = false;
  const success = nightly.last_success;

  if (success?.version) {
    chip.textContent = success.version;

    // The chip now names a newer build than the manifest card and the
    // changelog do. Saying so is the whole point -- an unexplained mismatch
    // between two numbers on one page is worse than either number alone.
    if (rendered && success.version !== rendered) {
      lines.push(`The manifest and changelog below describe ${rendered}, the build this page was rendered from.`);
    }

    const days = daysSince(success.finished);
    if (days !== null && days >= 2) {
      lines.push(`Last successful build was ${days} days ago.`);
      stale = true;
    }
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
  if (stale) chip.closest('.build-chip')?.setAttribute('data-stale', '');

  if (!lines.length) return;
  note.textContent = lines.join(' ');
  note.hidden = false;
}
