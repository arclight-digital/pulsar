#!/usr/bin/env bash
# The nightly, as the build host runs it.
#
# Everything here is deliberately thin: compute the version, call the
# pipeline, tell the dead-man's switch it finished. The pipeline itself is
# scripts/build.sh, which is the same code a workstation and a GitHub runner
# call, so this adds scheduling and alerting and nothing else.
#
# A timer that silently stops firing is the classic failure of moving off
# hosted CI: GitHub emails when a workflow fails, a systemd timer does not.
# PULSAR_HEALTHCHECK_URL is pinged only on success, so a missed or failed run
# raises an alert by omission. If it is unset this still runs -- it just runs
# unwatched, and says so.
#
# Fail-closed throughout. In particular the nvidia variant cannot build
# without the signer, and a night with no signer publishes nothing at all
# rather than publishing half a release.
#
# Configuration comes from the environment, normally /etc/pulsar/build.env:
#   IMAGE, IMAGE_NVIDIA         registry names
#   PULSAR_SIGNER_URL           the signing oracle, on the private VPC
#   PULSAR_SIGNER_TOKEN_FILE    bearer token, root-owned, 0400
#   PULSAR_BUILD_WORK           OCI layouts; wants the big volume
#   PULSAR_HEALTHCHECK_URL      pinged on success (optional)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

IMAGE="${IMAGE:?IMAGE is not set}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:?IMAGE_NVIDIA is not set}"
FEDORA_VERSION="${FEDORA_VERSION:-44}"
WORK="${PULSAR_BUILD_WORK:-/var/mnt/pulsar-build}"

started="$(date -u +%s)"
echo "pulsar nightly starting $(date -u -Iseconds)"

# The repo is the source of truth for what gets built; a build host that
# quietly builds a stale checkout is worse than one that fails.
git fetch --quiet origin main
git checkout --quiet -B main origin/main
echo "building $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"

VERSION="$("${REPO}/scripts/next-version.sh" --fedora "${FEDORA_VERSION}" "${IMAGE}")"
echo "this build is ${VERSION}"

"${REPO}/scripts/build.sh" \
  --variant all \
  --version "${VERSION}" \
  --image "${IMAGE}" \
  --image-nvidia "${IMAGE_NVIDIA}" \
  --signer-url "${PULSAR_SIGNER_URL:?PULSAR_SIGNER_URL is not set}" \
  --signer-token-file "${PULSAR_SIGNER_TOKEN_FILE:?PULSAR_SIGNER_TOKEN_FILE is not set}" \
  --work "${WORK}" \
  --push

elapsed=$(( $(date -u +%s) - started ))
echo "pulsar nightly ${VERSION} finished in ${elapsed}s"

if [ -n "${PULSAR_HEALTHCHECK_URL:-}" ]; then
  curl -fsS --max-time 20 --retry 3 \
    --data-binary "${VERSION} ok in ${elapsed}s" \
    "${PULSAR_HEALTHCHECK_URL}" >/dev/null \
    || echo "WARNING: healthcheck ping failed; the build itself succeeded" >&2
else
  echo "NOTE: PULSAR_HEALTHCHECK_URL unset -- nothing is watching this timer." >&2
fi
