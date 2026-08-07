#!/usr/bin/env bash
# The nightly, as an ephemeral builder runs it.
#
# This is the entry point the builder's cloud-init calls: compute the version,
# call the pipeline, tell the dead-man's switch it finished. It lives here
# rather than in arclight-infra because it is build logic, and the repo that
# knows how Pulsar is built should own it -- the infra repo spawns a droplet
# and hands it a ref, and everything after that is this.
#
# Deliberately thin, and it stays a scheduler. The pipeline is
# scripts/build.sh and everything downstream of the push is
# scripts/publish.sh -- the same code a workstation runs. This adds
# versioning, ordering and alerting, nothing else.
#
# A timer that silently stops firing is the classic failure of moving off
# hosted CI: GitHub emails when a workflow fails, a systemd timer does not,
# and an ephemeral droplet that dies early leaves nothing behind to notice.
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
#   PULSAR_SIGNER_CA_FILE       the signer's TLS certificate. Public, not a
#                               secret, and NOT the module-signing cert --
#                               this one secures the channel, /cert returns
#                               the other. Required: the build cannot verify
#                               a self-signed VPC certificate without it.
#   PULSAR_BUILD_WORK           OCI layouts; wants the big volume
#   PULSAR_HEALTHCHECK_URL      pinged on success (optional)
#   R2_BUCKET, R2_ACCOUNT_ID    where SBOMs and changelogs are published
#   R2_CREDENTIALS_FILE         file setting AWS_ACCESS_KEY_ID/SECRET, or set
#                               those directly. Required unless PULSAR_PUBLISH
#                               is no -- see the note in publish.sh for why it
#                               is not allowed to degrade quietly.
#   PULSAR_GIT_TOKEN_FILE       token for the site commit
#   PULSAR_PUBLISH_BRANCH       branch the site commit lands on (default main)
#   PULSAR_PUBLISH              yes (default) | dry-run | no
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

IMAGE="${IMAGE:?IMAGE is not set}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:?IMAGE_NVIDIA is not set}"
FEDORA_VERSION="${FEDORA_VERSION:-44}"
WORK="${PULSAR_BUILD_WORK:-/var/mnt/pulsar-build}"

# All of it in one function, because publish.sh syncs the checkout to origin
# before it commits and that rewrites this file underneath the running shell.
# Bash parses a function whole; it re-reads the file by offset between
# top-level statements, and there are none left after the call below.
main() {

started="$(date -u +%s)"
echo "pulsar nightly starting $(date -u -Iseconds)"

# The checkout belongs to whatever spawned this: the builder's cloud-init
# clones this repo at an explicit ref, so re-fetching here would silently
# build something other than what was asked for. Just say what is being built.
echo "building $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"

VERSION="$("${REPO}/scripts/next-version.sh" --fedora "${FEDORA_VERSION}" "${IMAGE}")"
echo "this build is ${VERSION}"

# MUST happen before the build. This is the image tonight's changelog says it
# came from, and the push below moves :latest onto the new one -- after that
# the outgoing digest is only recoverable if someone wrote it down, and this
# is the someone. Empty on the very first run, which is the baseline case and
# not an error.
PREV_DIGEST="$(oras resolve "${IMAGE}:latest" 2>/dev/null || true)"
echo "previous :latest digest: ${PREV_DIGEST:-<none, first build>}"

"${REPO}/scripts/build.sh" \
  --variant all \
  --version "${VERSION}" \
  --image "${IMAGE}" \
  --image-nvidia "${IMAGE_NVIDIA}" \
  --signer-url "${PULSAR_SIGNER_URL:?PULSAR_SIGNER_URL is not set}" \
  --signer-token-file "${PULSAR_SIGNER_TOKEN_FILE:?PULSAR_SIGNER_TOKEN_FILE is not set}" \
  --signer-ca-file "${PULSAR_SIGNER_CA_FILE:?PULSAR_SIGNER_CA_FILE is not set}" \
  --work "${WORK}" \
  --push

# Describe what was just published: SBOMs onto the images, the changelog
# against last night, the page. Part of the nightly rather than a step after
# it -- an image nobody can inspect is a blob users are asked to trust, and a
# night that ships one without saying what changed has not finished.
case "${PULSAR_PUBLISH:-yes}" in
  no) echo "PULSAR_PUBLISH=no -- images pushed, nothing described" >&2 ;;
  *)
    publish_args=(
      --version "${VERSION}"
      --image "${IMAGE}"
      --image-nvidia "${IMAGE_NVIDIA}"
      --prev-digest "${PREV_DIGEST}"
      --work "${WORK}"
      --branch "${PULSAR_PUBLISH_BRANCH:-main}"
    )
    [ "${PULSAR_PUBLISH:-yes}" = dry-run ] && publish_args+=(--dry-run)
    [ -n "${PULSAR_GIT_TOKEN_FILE:-}" ] \
      && publish_args+=(--git-token-file "${PULSAR_GIT_TOKEN_FILE}")
    "${REPO}/scripts/publish.sh" "${publish_args[@]}"
    ;;
esac

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

}

main
