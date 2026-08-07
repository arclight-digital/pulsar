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
# has no notion of a run number at all.
#
# A lookup that FAILS is fatal. It used to fall back to .0, excused as "the
# same tag the old scheme produced" -- but the old scheme's tag collision was
# the bug, so the fallback quietly reintroduced it behind a rarer trigger. It
# fired on 2026-08-07: two host runs both computed .0, the second replaced the
# first in the registry, and the machine booted on the first was left running
# an image no tag pointed at any more. An unanswered registry means the next
# number is UNKNOWN, and a version scheme that guesses when it does not know
# is not a version scheme.
#
# The one exception is a repository that does not exist yet, which a registry
# MAY report distinctly from every other failure. That is a genuine first build
# and .0 is the right answer for it -- so it is matched narrowly, on the error
# the registry itself returns, and announced rather than assumed.
#
# ghcr.io is not one of those registries: it answers 403 for a repository that
# does not exist, because it will not issue a pull token for a name it has
# never heard of. "It is not there" and "you may not look" arrive identically,
# so the first build of a NEW image here exits 3 and wants a human, who can
# push a first tag by hand. That is the correct trade: reading a 403 as "empty"
# would mean an expired credential silently restarts numbering at .0, which is
# this bug again wearing a different hat.
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
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) IMAGE="$1" ;;
  esac
  shift
done
: "${IMAGE:?usage: next-version.sh [--fedora N] <image>}"

command -v oras >/dev/null || { echo "missing: oras" >&2; exit 2; }

day="$(date -u +%Y%m%d)"
prefix="${FEDORA_VERSION}.${day}"

# stderr is captured rather than discarded because it carries the only thing
# that separates "this repository has never been pushed" from "the registry
# did not answer", and those two need opposite outcomes.
if tags="$(oras repo tags "${IMAGE}" 2>&1)"; then
  :
elif printf '%s' "${tags}" \
     | grep -qiE 'NAME_UNKNOWN|repository name not known|repository not found'; then
  echo "${IMAGE}: no such repository yet -- treating this as its first build" >&2
  tags=""
else
  echo "could not list tags for ${IMAGE}; refusing to guess a version" >&2
  printf '%s\n' "${tags}" >&2
  exit 3
fi

n=0
existing="$(printf '%s\n' "${tags}" | grep -E "^${prefix}\.[0-9]+$" || true)"
if [ -n "${existing}" ]; then
  n=$(printf '%s\n' "${existing}" | sed "s/^${prefix}\.//" | sort -n | tail -1)
  n=$((n + 1))
fi

printf '%s.%s\n' "${prefix}" "${n}"
