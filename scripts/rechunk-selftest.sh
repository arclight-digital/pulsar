#!/usr/bin/env bash
# Exercise the whole rechunk path against a toy image, in minutes, anywhere.
#
# The rechunk half of the build is where everything has actually broken --
# --from resolving to a registry pull instead of local storage, /mnt vs
# /var/mnt, podman version skew on containers-storage:, layer counts -- and
# until this script it was also the half with no local path. Every question
# cost a 30-minute CI round trip, or, on a day GitHub Actions is degraded,
# could not be asked at all.
#
# A toy image answers the same questions as the real one. It is silverblue
# plus three marker files, so it chunks in minutes rather than half an hour,
# and every mechanism under test -- reference resolution, the mount, the
# metadata round trip -- behaves identically regardless of how much content
# sits behind it.
#
# The toy is deliberately named like production. `localhost/foo` is not a
# registry, so a reference that falls back to a registry pull fails loudly;
# `ghcr.io/...` IS one, so the same fallback silently pulls a DIFFERENT image
# and the build ships content it never built. That is the bug this repo hit,
# and the reason it survived weeks of local builds: scripts/build.sh used a
# name shape that could not reproduce it. A self-test that tests the safe
# name shape tests nothing.
#
# Usage:
#   rechunk-selftest.sh                  build the toy, then ask everything
#   rechunk-selftest.sh --no-build       reuse a toy image already built
#   rechunk-selftest.sh --work DIR       where layouts go (needs a few GB)
#   rechunk-selftest.sh --quick          reference resolution only, no chunk
#
# Exit: 0 all questions answered and the answers are good, 1 a check failed,
#       2 could not determine.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEDORA_VERSION="${FEDORA_VERSION:-44}"
# registry-shaped on purpose, and never pushed -- see the header
TOY="${TOY:-ghcr.io/arclight-digital/pulsar-selftest}"
BASE_IMAGE="quay.io/fedora-ostree-desktops/silverblue:${FEDORA_VERSION}"

# Not /tmp: it is tmpfs on a Fedora desktop, and these layouts are gigabytes.
WORK="${PULSAR_SELFTEST_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/pulsar-selftest}"
DO_BUILD=yes
QUICK=no

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=no ;;
    --quick)    QUICK=yes ;;
    --work)     WORK="${2:?--work needs a directory}"; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

for tool in podman skopeo jq tar timeout; do
  command -v "${tool}" >/dev/null || { echo "missing: ${tool}" >&2; exit 2; }
done

mkdir -p "${WORK}" || exit 2

# ---------------------------------------------------------------------------
# The store, as podman actually has it rather than as a constant.
#
# CI puts the graphroot on the big temp disk at /mnt/podman; a workstation
# leaves it under $HOME or /var/lib. The tool has to see the same store the
# build wrote to, which means the SAME absolute path -- the storage database
# records absolute paths and a relocated graphroot is refused -- so the mount
# target is derived, with one exception: inside an ostree image /mnt is a
# symlink to var/mnt, so a /mnt graphroot must be mounted at /var/mnt to
# resolve back to the path storage.conf declares.
# ---------------------------------------------------------------------------
GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
RUNROOT="$(podman info --format '{{.Store.RunRoot}}' 2>/dev/null)"
DRIVER="$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null)"
[ -n "${GRAPHROOT}" ] && [ -n "${DRIVER}" ] || { echo "cannot read podman store info" >&2; exit 2; }

case "${GRAPHROOT}" in
  /mnt/*) MOUNT_TARGET="/var${GRAPHROOT}" ;;
  *)      MOUNT_TARGET="${GRAPHROOT}" ;;
esac

STORAGE_CONF="${WORK}/storage.conf"
printf '[storage]\ndriver = "%s"\ngraphroot = "%s"\nrunroot = "%s"\n' \
  "${DRIVER}" "${GRAPHROOT}" "${RUNROOT}" > "${STORAGE_CONF}"

case "${WORK}" in
  /mnt/*) WORK_TARGET="/var${WORK}" ;;
  *)      WORK_TARGET="${WORK}" ;;
esac

echo "store:  ${GRAPHROOT} (${DRIVER}) mounted at ${MOUNT_TARGET}"
echo "work:   ${WORK} mounted at ${WORK_TARGET}"
echo

# ---------------------------------------------------------------------------
# The toy. One marker per class of content that froze in production: a
# packaged file modified after install, an unpackaged file, and a generated
# file in a package-owned directory.
# ---------------------------------------------------------------------------
if [ "${DO_BUILD}" = yes ]; then
  cat > "${WORK}/Containerfile.toy" <<EOF
FROM ${BASE_IMAGE}
RUN sed -i 's|^VERSION=.*|VERSION="SELFTEST"|' /usr/lib/os-release \\
 && echo SELFTEST > /usr/lib/pulsar-selftest-unowned \\
 && echo SELFTEST > /usr/share/pixmaps/pulsar-selftest-generated
EOF
  echo "==> building the toy image"
  podman build --pull=newer -f "${WORK}/Containerfile.toy" \
    -t "${TOY}:${FEDORA_VERSION}" "${WORK}" || exit 2
  echo
fi
podman image exists "${TOY}:${FEDORA_VERSION}" \
  || { echo "no toy image; drop --no-build" >&2; exit 2; }

# an OCI layout the tool can open: it opens the destination BEFORE it
# resolves --from, so an unseeded one masks the answer with an output error
seed() {
  rm -rf "${WORK:?}/${1:?}"
  mkdir -p "${WORK}/$1/blobs/sha256" || return 1
  printf '{"imageLayoutVersion":"1.0.0"}' > "${WORK}/$1/oci-layout"
  printf '{"schemaVersion":2,"manifests":[]}' > "${WORK}/$1/index.json"
}

chunk() {
  local slot="$1"; shift
  seed "${slot}" || return 2
  # CHUNK_TIMEOUT wraps the container, not this function -- `timeout` execs a
  # binary and cannot see a shell function, which is how the first version of
  # this script reported three inconclusive verdicts that were really one typo.
  local -a limit=()
  [ -n "${CHUNK_TIMEOUT:-}" ] && limit=(timeout "${CHUNK_TIMEOUT}")
  "${limit[@]}" podman run --rm --privileged \
    -v "${GRAPHROOT}:${MOUNT_TARGET}" \
    -v "${WORK}:${WORK_TARGET}" \
    -v "${STORAGE_CONF}:/etc/containers/storage.conf:ro" \
    "${TOY}:${FEDORA_VERSION}" \
    rpm-ostree compose build-chunked-oci --bootc --format-version 1 \
      --max-layers 200 \
      "$@" \
      --output "oci:${WORK}/${slot}:build"
}

# "Generating commit" means it resolved from storage, which is the whole
# question. "Trying to pull" is the silent fallback that caused this.
verdict() {
  local name="$1" log="$2"
  if grep -q "Trying to pull" "${log}"; then
    echo "  ${name}: FELL BACK TO REGISTRY PULL"; return 1
  elif grep -qE "Generating commit|Building package mapping|Committing" "${log}"; then
    echo "  ${name}: RESOLVED FROM LOCAL STORAGE"; return 0
  fi
  echo "  ${name}: inconclusive"
  tail -6 "${log}" | sed 's/^/      /'
  return 2
}

# ---------------------------------------------------------------------------
# Does --from read the image we just built? A verdict arrives in seconds, so
# nothing here runs long enough to finish chunking.
#
# --from names an image in containers-storage and takes no transport prefix:
# the tool adds `containers-storage:` itself, and writing it out produces
# `containers-storage:containers-storage:...` and a parse error. So the form
# is settled, and what is worth testing is the FAILURE mode, because it is
# silent. When the store is unreadable the tool pulls the name from a
# registry instead of stopping, and a registry-shaped name succeeds at
# pulling something -- a different image, chunked and shipped as though it
# were this build.
# ---------------------------------------------------------------------------
FAILURES=0

echo "==> does --from read local storage?"
CHUNK_TIMEOUT=120 chunk resolve --from "${TOY}:${FEDORA_VERSION}" > "${WORK}/resolve.log" 2>&1
verdict "${TOY}:${FEDORA_VERSION}" "${WORK}/resolve.log" || FAILURES=$((FAILURES + 1))

# The silent fallback itself. An image that is definitely not in the store
# must NOT be quietly fetched -- and it is, which is why the build asserts on
# content afterwards rather than trusting this to fail.
echo
echo "==> what happens when the image is NOT in the store?"
CHUNK_TIMEOUT=120 chunk absent \
  --from "${TOY}-does-not-exist:${FEDORA_VERSION}" > "${WORK}/absent.log" 2>&1
if grep -q "Trying to pull" "${WORK}/absent.log"; then
  echo "  falls back to a registry pull, silently -- as expected, and why"
  echo "  build.yml asserts on os-release content after every rechunk"
else
  echo "  no registry fallback observed; the build's content assertion may"
  echo "  now be guarding a failure mode that no longer exists"
  tail -4 "${WORK}/absent.log" | sed 's/^/      /'
fi

# The regression test for the bug this script was written to find. A
# graphroot that resolves, through a symlink, to something other than what
# the store's database recorded must FAIL rather than silently fall back.
# On the runner /mnt is a real directory and inside the image it is a symlink
# to var/mnt, which is precisely how weeks of builds shipped stale content.
echo
echo "==> and when the graphroot resolves somewhere else?"
printf '[storage]\ndriver = "%s"\ngraphroot = "/mnt/podman"\nrunroot = "%s"\n' \
  "${DRIVER}" "${RUNROOT}" > "${WORK}/mismatch.conf"
seed mismatch
CHUNK_TIMEOUT=120 podman run --rm --privileged \
  -v "${GRAPHROOT}:/var/mnt/podman" \
  -v "${WORK}:${WORK_TARGET}" \
  -v "${WORK}/mismatch.conf:/etc/containers/storage.conf:ro" \
  "${TOY}:${FEDORA_VERSION}" \
  rpm-ostree compose build-chunked-oci --bootc --format-version 1 \
    --from "${TOY}:${FEDORA_VERSION}" \
    --output "oci:${WORK_TARGET}/mismatch:build" > "${WORK}/mismatch.log" 2>&1
if grep -q "configuration mismatch" "${WORK}/mismatch.log"; then
  echo "  refused with a database configuration mismatch, loudly"
elif grep -q "Trying to pull" "${WORK}/mismatch.log"; then
  echo "  SILENTLY PULLED instead of refusing -- this is the shipped-stale bug"
  FAILURES=$((FAILURES + 1))
else
  echo "  inconclusive"
  tail -4 "${WORK}/mismatch.log" | sed 's/^/      /'
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  echo "reference resolution is not behaving; logs in ${WORK}" >&2
  exit 1
fi
WINNER="${TOY}:${FEDORA_VERSION}"
[ "${QUICK}" = yes ] && exit 0

# ---------------------------------------------------------------------------
# Resolving locally is still an inference until the bytes are read back. Run
# the winner to completion and find the marker in what it wrote: SELFTEST can
# only be there if the tool read the image this script built, because no such
# image was ever pushed anywhere.
# ---------------------------------------------------------------------------
echo
echo "==> chunking for real with the winning reference"
if ! chunk proof --from "${WINNER}" > "${WORK}/proof.log" 2>&1; then
  echo "the winning reference failed a full chunk; see ${WORK}/proof.log" >&2
  tail -20 "${WORK}/proof.log" >&2
  exit 1
fi
grep -cE '^' "${WORK}/proof.log" >/dev/null

layers=$(skopeo inspect "oci:${WORK}/proof:build" 2>/dev/null | jq -r '.Layers | length')
echo "chunked into ${layers:-?} layers"

found=no
for blob in "${WORK}/proof/blobs/sha256/"*; do
  if tar -tf "${blob}" 2>/dev/null | grep -q 'usr/lib/pulsar-selftest-unowned'; then
    found=yes; break
  fi
done
if [ "${found}" != yes ]; then
  echo "the chunked output does NOT contain this build's marker" >&2
  exit 1
fi
echo "marker present: the chunked output holds the image this script built"

# ---------------------------------------------------------------------------
# And what did the round trip do to the metadata? Same script the build runs
# before it pushes, so the baseline learned here is the one that gates there.
# ---------------------------------------------------------------------------
echo
echo "==> what did the rechunk do to modes and ownership?"
"${REPO}/scripts/diff-chunk-metadata.sh" "${TOY}:${FEDORA_VERSION}" "${WORK}/proof" build
rc=$?
echo
echo "artifacts kept in ${WORK} (rm -rf to reclaim the space)"
exit "${rc}"
