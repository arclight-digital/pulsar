#!/usr/bin/env bash
# Will tonight's nvidia image build? Asked in the morning, on the base image
# the night will build on.
#
# The nvidia image compiles rpmfusion's nvidia-open against whatever kernel
# Fedora's base image carries that day. Nothing ties the two together: on
# 2026-11-11 the base moved to kernel 7.3.3, nvidia-open 615.71.09 did not
# compile against it, and the first anyone knew was a failed nightly. This
# runs the same compile on its own, so a mismatch is an alert with hours to
# spare.
#
#   scripts/driver-check.sh                 the base nightly.sh builds on
#   scripts/driver-check.sh --base IMAGE    another base, by reference
#
# It pulls the base, and inside it (scripts/driver-check-inner.sh) installs
# kernel-devel for the base's own kernel, takes the akmod-nvidia-open
# rpmfusion ships today, applies rpmfusion's patch and every patch in
# patches/nvidia-open/series exactly as phase 2b of Containerfile.nvidia
# does, and compiles the modules. It signs nothing and pushes nothing.
#
# Exit 0 the modules build, 1 they do not (a carried patch no longer applies,
# or the compile fails), 2 could not tell (no podman, a pull or a mirror that
# failed). Infra's spawn-builder.sh --kind driver runs it every morning
# through nightly.sh --driver-check and alerts on 1.
#
# The patches and the inner script go in on stdin as a tar, not as a bind
# mount: a mount needs :Z under SELinux, and :Z relabels the checkout.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEDORA_VERSION="${FEDORA_VERSION:-45}"
# Kept in step with build.sh and nightly.sh, which name the same base.
BASE="${BASE_IMAGE:-quay.io/fedora-ostree-desktops/silverblue}:${FEDORA_VERSION}"

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?--base needs an image reference}"; shift ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v podman >/dev/null || { echo "driver-check: could not tell: podman is not installed" >&2; exit 2; }
[ -r "${REPO}/patches/nvidia-open/series" ] \
  || { echo "driver-check: could not tell: no patches/nvidia-open/series" >&2; exit 2; }

echo "driver-check: pulling ${BASE}"
podman pull -q "${BASE}" >/dev/null \
  || { echo "driver-check: could not tell: ${BASE} would not pull" >&2; exit 2; }

stage="$(mktemp -d -t driver-check-XXXXXX)"
trap 'rm -rf "${stage}"' EXIT
cp -a "${REPO}/patches/nvidia-open/." "${stage}/"
cp "${REPO}/scripts/driver-check-inner.sh" "${stage}/.driver-check-inner.sh"

rc=0
tar -C "${stage}" -cf - . \
  | podman run --rm -i --pull=never "${BASE}" \
      bash -c 'mkdir -p /patches && tar -C /patches -xf - && exec bash /patches/.driver-check-inner.sh' \
  || rc=$?

case "${rc}" in
  0|1|2) exit "${rc}" ;;
  *) echo "driver-check: could not tell: the container exited ${rc}" >&2; exit 2 ;;
esac
