#!/usr/bin/env bash
# What should this build be called?
#
# Fedora's own shape: <release>.<YYYYMMDD>.<n>. The n is not decoration. The
# tag was once just 44.<date> and was documented as "immutable per-build",
# which it was not: two pushes on one day computed the same tag and the second
# silently replaced the first. That happened twice on 2026-08-05 alone, so
# "pin to last Tuesday's build" was pinning to whatever landed last that
# Tuesday.
#
# n comes from what the registry already holds rather than from a run counter,
# so it stays correct across re-runs, manual dispatches, and a build host that
# has no notion of a run number at all. An unreachable registry falls back to
# .0 rather than failing -- the same tag the old scheme produced.
#
# Lives here rather than in the workflow because the build host needs the same
# answer, and two implementations of a version scheme is how you get two
# builds claiming one tag.
#
#   next-version.sh ghcr.io/arclight-digital/pulsar        -> 44.20260806.3
#   next-version.sh --fedora 45 ghcr.io/...                -> 45.20260806.0
set -euo pipefail

FEDORA_VERSION="${FEDORA_VERSION:-44}"
while [ $# -gt 0 ]; do
  case "$1" in
    --fedora) FEDORA_VERSION="${2:?}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) IMAGE="$1" ;;
  esac
  shift
done
: "${IMAGE:?usage: next-version.sh [--fedora N] <image>}"

command -v oras >/dev/null || { echo "missing: oras" >&2; exit 2; }

day="$(date -u +%Y%m%d)"
prefix="${FEDORA_VERSION}.${day}"

n=0
existing="$(oras repo tags "${IMAGE}" 2>/dev/null | grep -E "^${prefix}\.[0-9]+$" || true)"
if [ -n "${existing}" ]; then
  n=$(printf '%s\n' "${existing}" | sed "s/^${prefix}\.//" | sort -n | tail -1)
  n=$((n + 1))
fi

printf '%s.%s\n' "${prefix}" "${n}"
