#!/usr/bin/env bash
# The weekly ISO build, as an ephemeral builder runs it.
#
# The entry point the ISO builder's cloud-init calls: both variants, in
# sequence, through scripts/build-iso.sh -- the same pipeline a workstation
# runs. This adds ordering, cleanup between variants and alerting, nothing
# else; it is nightly.sh's shape applied to installers.
#
# Sequential on purpose, with a cleanup between: the ISO droplet is
# root-disk-only (no cache volume -- see build-iso.sh for why the store must
# sit at the default graphroot), and one variant's image plus osbuild store
# plus ISO fits where two at once would not.
#
# PULSAR_ISO_HEALTHCHECK_URL is pinged only on success, so a missed or failed
# week raises an alert by omission -- its own check, not the nightly's: the
# two run on different cadences and a dead weekly must not hide behind a
# healthy nightly.
#
# Fail-closed throughout: no signer or no R2 means nothing is published, not
# half a release. build-iso.sh enforces both before it builds anything.
#
# Configuration comes from the environment, normally /etc/pulsar/build.env:
#   IMAGE, IMAGE_NVIDIA           registry names to build ISOs from
#   PULSAR_SIGNER_URL             signd, for the release-key signature
#   PULSAR_SIGNER_TOKEN_FILE      bearer token, root-owned, 0400
#   PULSAR_SIGNER_CA_FILE         signd's TLS certificate
#   PULSAR_ISO_WORK               scratch; ~40GB per variant, reclaimed between
#   PULSAR_ISO_HEALTHCHECK_URL    pinged on success (optional)
#   R2_BUCKET, R2_ACCOUNT_ID      where ISOs are published
#   R2_CREDENTIALS_FILE           file setting AWS_ACCESS_KEY_ID/SECRET
set -euo pipefail

# Same as nightly.sh: cloud-init's runcmd sets no $HOME, and the aws CLI
# build-iso.sh publishes through expands ~ for its config and cache.
# Derived, not assumed -- see the nightly for the full story.
if [ -z "${HOME:-}" ]; then
  HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
  [ -n "${HOME}" ] || { echo "no \$HOME and no passwd entry for uid $(id -u)" >&2; exit 2; }
  export HOME
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

IMAGE="${IMAGE:?IMAGE is not set}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:?IMAGE_NVIDIA is not set}"
WORK="${PULSAR_ISO_WORK:-/var/tmp/pulsar-iso}"

started="$(date -u +%s)"
echo "pulsar weekly ISO build starting $(date -u -Iseconds)"
echo "building from $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"

# Same gate as the nightly: with no on-push CI, the entry points are where
# lint and tests run, and an ISO signed and published from a repo state that
# cannot pass its own checks is not a state this allows.
"${REPO}/scripts/check.sh"

for variant in vanilla nvidia; do
  case "${variant}" in
    vanilla) image="${IMAGE}" ;;
    nvidia)  image="${IMAGE_NVIDIA}" ;;
  esac

  "${REPO}/scripts/build-iso.sh" \
    --variant "${variant}" \
    --image "${image}" \
    --work "${WORK}" \
    --signer-url "${PULSAR_SIGNER_URL:?PULSAR_SIGNER_URL is not set}" \
    --signer-token-file "${PULSAR_SIGNER_TOKEN_FILE:?PULSAR_SIGNER_TOKEN_FILE is not set}" \
    --signer-ca-file "${PULSAR_SIGNER_CA_FILE:?PULSAR_SIGNER_CA_FILE is not set}" \
    --push

  # Reclaim the disk before the next variant: the pulled OS image and the
  # osbuild store are the two multi-GB items, and neither is reusable across
  # variants. --all because a digest-pull leaves no tag for rmi to name; it
  # also drops the bib image, whose re-pull is noise next to the ~10GB OS
  # image either way.
  podman image prune --all --force >/dev/null || true
  rm -rf "${WORK}/iso" "${WORK}/store"
done

elapsed=$(( $(date -u +%s) - started ))
echo "pulsar weekly ISO build finished in ${elapsed}s"

if [ -n "${PULSAR_ISO_HEALTHCHECK_URL:-}" ]; then
  curl -fsS --max-time 20 --retry 3 \
    --data-binary "weekly isos ok in ${elapsed}s" \
    "${PULSAR_ISO_HEALTHCHECK_URL}" >/dev/null \
    || echo "WARNING: healthcheck ping failed; the build itself succeeded" >&2
else
  echo "NOTE: PULSAR_ISO_HEALTHCHECK_URL unset -- nothing is watching this timer." >&2
fi
