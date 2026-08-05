#!/usr/bin/env bash
# Diff two SPDX SBOMs into changelog.json.
#
#   sbom-changelog.sh OLD.spdx.json NEW.spdx.json > changelog.json
#
# This is the thing the nightly image is actually FOR: an image nobody can
# inspect is just a blob you are asked to trust. Every package that appeared,
# vanished, or moved between two builds, with both versions, derived from the
# SBOMs that ship attached to the images themselves -- not from a hand-written
# release note that can quietly disagree with what was built.
#
# Direction (upgraded vs downgraded) is decided by rpmdev-vercmp when it is
# available, because RPM version ordering is not string ordering and not
# `sort -V` either: epochs, tildes (pre-release, sorts BEFORE the base) and
# carets all have rules those get wrong. When rpmdev-vercmp is absent the
# entry is still reported, honestly labelled "changed" rather than guessed at.
# Run this inside a Fedora container to get the real comparator.
#
# Optional metadata, all via env so CI can stamp provenance onto the diff:
#   FROM_REF / TO_REF        image references being compared
#   FROM_DIGEST / TO_DIGEST  their digests
#   GENERATED                ISO-8601 timestamp (defaults to now, UTC)
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $(basename "$0") OLD.spdx.json NEW.spdx.json" >&2
    exit 2
fi

OLD=$1
NEW=$2

for f in "$OLD" "$NEW"; do
    [ -r "$f" ] || { echo "cannot read SBOM: $f" >&2; exit 1; }
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Set diff. Keyed on package name; versionInfo is the value.
#
# from_entries keeps the LAST entry when a name repeats, which happens for
# genuinely multi-arch installs (an i686 and an x86_64 of the same library).
# That collapses such a pair to one row rather than reporting a phantom
# change, which is the behaviour we want in a human-facing changelog.
# ---------------------------------------------------------------------------
raw=$(jq -n --slurpfile old "$OLD" --slurpfile new "$NEW" '
  def pkgmap:
    [ .packages[]? | select(.versionInfo != null and .name != null)
      | {key: .name, value: .versionInfo} ] | from_entries;
  ($old[0] | pkgmap) as $o |
  ($new[0] | pkgmap) as $n |
  {
    added:   [ $n | to_entries[] | select($o[.key] == null)
               | {name: .key, version: .value} ] | sort_by(.name),
    removed: [ $o | to_entries[] | select($n[.key] == null)
               | {name: .key, version: .value} ] | sort_by(.name),
    changed: [ $n | to_entries[] | select($o[.key] != null and $o[.key] != .value)
               | {name: .key, from: $o[.key], to: .value} ] | sort_by(.name)
  }')

# ---------------------------------------------------------------------------
# Classify each change. rpmdev-vercmp exits 11 when the first argument is
# newer and 12 when the second is; 0 means equal. It also exits nonzero on
# usage errors, so anything outside that set is treated as undetermined
# rather than silently becoming an "upgrade".
# ---------------------------------------------------------------------------
if command -v rpmdev-vercmp >/dev/null; then
    directions=$(
        jq -r '.changed[] | "\(.name)\t\(.from)\t\(.to)"' <<<"$raw" |
        while IFS=$'\t' read -r name from to; do
            set +e
            rpmdev-vercmp "$from" "$to" >/dev/null 2>&1
            rc=$?
            set -e
            case "$rc" in
                12) dir=upgraded ;;
                11) dir=downgraded ;;
                *)  dir=changed ;;
            esac
            printf '%s\t%s\n' "$name" "$dir"
        done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t"))
                            | map({key: .[0], value: .[1]}) | from_entries'
    )
else
    echo "warning: rpmdev-vercmp not found; changes reported without direction" >&2
    directions='{}'
fi

jq -n \
  --argjson raw "$raw" \
  --argjson dir "$directions" \
  --arg generated "${GENERATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
  --arg from_ref "${FROM_REF:-}" \
  --arg to_ref "${TO_REF:-}" \
  --arg from_digest "${FROM_DIGEST:-}" \
  --arg to_digest "${TO_DIGEST:-}" '
  ($raw.changed | map(. + {direction: ($dir[.name] // "changed")})) as $changed |
  {
    generated: $generated,
    from: {ref: $from_ref, digest: $from_digest},
    to:   {ref: $to_ref,   digest: $to_digest},
    summary: {
      added:      ($raw.added   | length),
      removed:    ($raw.removed | length),
      upgraded:   ($changed | map(select(.direction == "upgraded"))   | length),
      downgraded: ($changed | map(select(.direction == "downgraded")) | length),
      changed:    ($changed | map(select(.direction == "changed"))    | length)
    },
    added:   $raw.added,
    removed: $raw.removed,
    changed: $changed
  }'
