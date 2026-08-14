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
#   PULSAR_CHANNEL              scheduled | manual. REQUIRED -- see below.
#   PULSAR_FORCE_BUILD          yes to build even when the base image has not
#                               moved -- see base_moved() below
#
# THE CHANNEL IS THE ONE THING THIS SCRIPT WILL NOT GUESS. A scheduled build is
# the one users pull; a manual build is one a person kicked off while working.
# Conflating them costs real things -- a hand-run build used to consume a number
# in the published series, move :latest onto a debugging image, and overwrite
# the SBOM baseline the next night diffs against.
#
# So an unset PULSAR_CHANNEL is a hard stop rather than a default. Both possible
# defaults are wrong in a way somebody pays for: guessing scheduled hands a
# debugging build every user's next bootc upgrade, and guessing manual leaves a
# nightly that quietly publishes nothing while looking like it worked. This is
# next-version.sh's "a version scheme that guesses when it does not know is not
# a version scheme", one level up.
#
# A manual build still builds, signs, verifies and pushes -- it is a real image
# anyone can pull, which is the point of running it. What it does not do is
# define anything: no floating tags, no baseline, no site commit, and no
# healthcheck ping.
set -euo pipefail

# cloud-init's runcmd is not a login shell: it runs as root with no $HOME.
# oras resolves the running user's home for its registry config and
# hard-fails without it -- and oras answers the version lookup, so no $HOME
# means no version. The old .0 fallback was almost certainly masking exactly
# this failure on every host run, which is how two builds computed .0 on
# 2026-08-07. Derived from the passwd entry rather than assumed to be /root:
# the directory exists, only the variable is missing.
if [ -z "${HOME:-}" ]; then
  HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
  [ -n "${HOME}" ] || { echo "no \$HOME and no passwd entry for uid $(id -u)" >&2; exit 2; }
  export HOME
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

IMAGE="${IMAGE:?IMAGE is not set}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:?IMAGE_NVIDIA is not set}"
FEDORA_VERSION="${FEDORA_VERSION:-44}"
WORK="${PULSAR_BUILD_WORK:-/var/mnt/pulsar-build}"
# Kept in step with build.sh, which records which digest of this a build used.
BASE_IMAGE="${BASE_IMAGE:-quay.io/fedora-ostree-desktops/silverblue}"

# All of it in one function, because publish.sh syncs the checkout to origin
# before it commits and that rewrites this file underneath the running shell.
# Bash parses a function whole; it re-reads the file by offset between
# top-level statements, and there are none left after the call below.
main() {

# ---------------------------------------------------------------------------
# Is there anything to build tonight?
#
# Neither Containerfile ever runs `dnf5 upgrade`. Every OS package in the image
# comes from quay's silverblue:${FEDORA_VERSION}; this build only INSTALLS on
# top of it. So when that tag has not moved since the last published build, the
# image tonight would produce carries the same package set as the one users are
# already running. That is not a hypothetical -- it is 2026-08-14, whose
# changelog came out zero across the board.
#
# Shipping it anyway is not free. The version label and the os-release stamp
# move on every build by construction, so the digest moves too, and `pulsar
# update --check` compares digests: every machine gets a notification and a
# multi-gigabyte pull for a package set it already has.
#
# WHAT THIS DOES NOT CATCH, deliberately, because catching it costs the build
# hour it is trying to save: the packages installed ON TOP of the base can move
# while the base is static -- scx-scheds from the copr, the rpmfusion bits,
# mise, and the nvidia driver. A night where only those moved is skipped, and
# picked up whenever the base next moves. To ship one without waiting, run with
# PULSAR_FORCE_BUILD=yes.
#
# FAILS OPEN, everywhere. Every path that cannot get a straight answer builds.
# A gate that skips when it cannot see would stop shipping updates in silence,
# and silence is exactly what this pipeline reserves for "the timer did not
# fire" -- a wasted build hour is the cheaper mistake by a wide margin.
# ---------------------------------------------------------------------------
base_moved() {
  # A manual build is somebody asking for this exact tree to be built. It is
  # never about the base, and refusing it because quay is quiet would be
  # refusing the one build a person is standing there waiting for.
  [ "${CHANNEL}" = scheduled ] || { echo "manual build: not gated on the base image"; return 0; }
  if [ "${PULSAR_FORCE_BUILD:-no}" = yes ]; then
    echo "PULSAR_FORCE_BUILD=yes: building regardless of the base"
    return 0
  fi
  command -v skopeo >/dev/null || { echo "no skopeo; cannot check the base, so building" >&2; return 0; }

  local now last
  now="$(skopeo inspect --no-tags --format '{{.Digest}}' \
           "docker://${BASE_IMAGE}:${FEDORA_VERSION}" 2>/dev/null || true)"
  [ -n "${now}" ] || { echo "could not resolve ${BASE_IMAGE}:${FEDORA_VERSION}; building" >&2; return 0; }

  # Absent on anything built before build.sh started writing this label, and on
  # the first push of a new image name. Both mean there is no comparison to be
  # made, which is not the same as the base being unchanged.
  last="$(skopeo inspect --no-tags \
            --format '{{index .Labels "digital.arclight.pulsar.base-digest"}}' \
            "docker://${IMAGE}:latest" 2>/dev/null || true)"
  case "${last}" in
    ""|"<no value>")
      echo "the published build records no base digest; building" >&2
      return 0 ;;
  esac

  if [ "${now}" = "${last}" ]; then
    echo "base ${BASE_IMAGE}:${FEDORA_VERSION} is still ${now}"
    return 1
  fi
  echo "base moved: ${last} -> ${now}"
  return 0
}

# One ping, two callers. The dead-man's switch watches the TIMER, so any night
# the timer did its job has to ping -- including a night that looked at the
# base and decided correctly that there was nothing to build. Omission means
# "the nightly did not run", and "the nightly ran and shipped nothing" must not
# borrow that meaning.
ping_healthcheck() {
  local what="$1"
  if [ "${CHANNEL}" = manual ]; then
    echo "manual build: healthcheck not pinged -- it watches the timer, and a ping" >&2
    echo "from here would hide a scheduled run that did not happen." >&2
  elif [ -n "${PULSAR_HEALTHCHECK_URL:-}" ]; then
    curl -fsS --max-time 20 --retry 3 \
      --data-binary "${what}" \
      "${PULSAR_HEALTHCHECK_URL}" >/dev/null \
      || echo "WARNING: healthcheck ping failed; the run itself succeeded" >&2
  else
    echo "NOTE: PULSAR_HEALTHCHECK_URL unset -- nothing is watching this timer." >&2
  fi
}

# Before anything is built, and before the checks: an unrecognised value is a
# config error, and an absent one is the build host failing to say what this is.
# Either way nothing here may pick for it. See the note in the header.
case "${PULSAR_CHANNEL:-}" in
  scheduled|manual) CHANNEL="${PULSAR_CHANNEL}" ;;
  "")
    echo "PULSAR_CHANNEL is not set, so this build cannot say whether it is the" >&2
    echo "one users pull or one somebody started by hand. Refusing to guess:" >&2
    echo "set PULSAR_CHANNEL=scheduled|manual in /etc/pulsar/build.env." >&2
    exit 2 ;;
  *)
    echo "PULSAR_CHANNEL=${PULSAR_CHANNEL} is not scheduled or manual" >&2
    exit 2 ;;
esac

started="$(date -u +%s)"
echo "pulsar nightly starting $(date -u -Iseconds) (${CHANNEL})"

# The checkout belongs to whatever spawned this: the builder's cloud-init
# clones this repo at an explicit ref, so re-fetching here would silently
# build something other than what was asked for. Just say what is being built.
echo "building $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"

# A manual build is allowed to run from a dirty checkout -- publish.sh's
# worktree refusal only guards the site commit, which a manual build skips, and
# building what you just edited is usually the whole reason for starting one.
# It is not allowed to be silent about it: the line above stops describing what
# was built, and the version tag outlives that fact.
if [ "${CHANNEL}" = manual ] && ! git diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: the worktree is dirty, so the commit above does not describe" >&2
  echo "         what is in this image. The tag will outlive that." >&2
fi

# The old on-push CI, run here now that there is no on-push anything: lint
# and tests gate the build, so a broken script on main is a failed nightly
# the same evening rather than a latent surprise. Forty seconds against an
# hour-long build.
"${REPO}/scripts/check.sh"

# AFTER check.sh, on purpose. Those forty seconds are what turns a broken
# script on main into a failed nightly the same evening, and a quiet night is
# still a night that should notice. Before next-version.sh, equally on purpose:
# a build that does not happen must not consume a number in the published
# series.
if ! base_moved; then
  elapsed=$(( $(date -u +%s) - started ))
  echo
  echo "nothing to build: no package in this image can have moved, so the"
  echo "published build is still current. Skipping tonight."
  echo "  published    $(oras resolve "${IMAGE}:latest" 2>/dev/null || echo '<unknown>')"
  echo "  to override  PULSAR_FORCE_BUILD=yes"
  ping_healthcheck "no build in ${elapsed}s: base unchanged"
  exit 0
fi

VERSION="$("${REPO}/scripts/next-version.sh" \
  --fedora "${FEDORA_VERSION}" --channel "${CHANNEL}" "${IMAGE}")"
# The build host scrapes this line for the version, so its shape is a contract:
# `grep -oP '^this build is \K.*'`. Keep the prefix exactly. The channel goes on
# its own line rather than into this one for the same reason.
echo "this build is ${VERSION}"
echo "channel: ${CHANNEL}"

# MUST happen before the build. This is the image tonight's changelog says it
# came from, and the push below moves :latest onto the new one -- after that
# the outgoing digest is only recoverable if someone wrote it down, and this
# is the someone. Empty on the very first run, which is the baseline case and
# not an error.
#
# On a manual build the push does NOT move :latest, so this resolves the last
# scheduled build and stays true afterwards. That is what makes a manual
# changelog worth reading: it diffs against what users are actually running.
PREV_DIGEST="$(oras resolve "${IMAGE}:latest" 2>/dev/null || true)"
echo "previous :latest digest: ${PREV_DIGEST:-<none, first build>}"

build_args=(
  --variant all
  --version "${VERSION}"
  --image "${IMAGE}"
  --image-nvidia "${IMAGE_NVIDIA}"
  --signer-url "${PULSAR_SIGNER_URL:?PULSAR_SIGNER_URL is not set}"
  --signer-token-file "${PULSAR_SIGNER_TOKEN_FILE:?PULSAR_SIGNER_TOKEN_FILE is not set}"
  --signer-ca-file "${PULSAR_SIGNER_CA_FILE:?PULSAR_SIGNER_CA_FILE is not set}"
  --work "${WORK}"
  --push
)
# :latest and :44 are what a machine follows on its next bootc upgrade. A
# debugging build must not become that, so it publishes its version tag and
# nothing else. build.sh also refuses to move the floating tags onto a -dev
# version even if this line is ever dropped.
[ "${CHANNEL}" = manual ] && build_args+=(--no-floating-tags)
"${REPO}/scripts/build.sh" "${build_args[@]}"

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
    # Per-build SBOMs and a changelog, but none of the moving pointers and no
    # site commit: a manual build describes itself without becoming the baseline
    # the next scheduled build diffs against.
    [ "${CHANNEL}" = manual ] && publish_args+=(--no-promote)
    [ -n "${PULSAR_GIT_TOKEN_FILE:-}" ] \
      && publish_args+=(--git-token-file "${PULSAR_GIT_TOKEN_FILE}")
    "${REPO}/scripts/publish.sh" "${publish_args[@]}"
    ;;
esac

elapsed=$(( $(date -u +%s) - started ))
echo "pulsar nightly ${VERSION} finished in ${elapsed}s"

# What the operator who started this needs to know, in one place: it exists, it
# is pullable, and it changed nothing about what anybody else gets.
if [ "${CHANNEL}" = manual ]; then
  echo
  echo "manual build ${VERSION}:"
  echo "  pushed        ${IMAGE}:${VERSION}"
  echo "                ${IMAGE_NVIDIA}:${VERSION}"
  echo "  not moved     :latest and :${FEDORA_VERSION} still point at the last scheduled build"
  echo "  not written   the SBOM baseline, the published changelog, the site"
  echo "  boot it       bootc switch ${IMAGE_NVIDIA}:${VERSION}"
fi

# NOT pinged on a manual build. This is a dead-man's switch on the TIMER: it
# alerts by omission, so a hand-run build that pinged it would mark the night as
# healthy and hide a scheduled run that never happened. The one case where doing
# less is the whole feature. ping_healthcheck holds that rule for both callers.
ping_healthcheck "${VERSION} ok in ${elapsed}s"

}

main
