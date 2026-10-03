#!/usr/bin/env bash
# check.sh as the nightly runs it -- as root, on a plain Fedora with the
# disk tools -- in a container, before a push. The container's image is
# built once and rebuilt only when its Containerfile changes or it is a
# week old (for Fedora's updates).
#
#   scripts/root-check.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=localhost/pulsar-root-check:44
ctx="${REPO}/tests/root-check"
want=$(sha256sum "${ctx}/Containerfile" | cut -c1-16)
have=$(podman image inspect --format '{{index .Labels "pulsar.containerfile"}}' "${IMAGE}" 2>/dev/null || true)
created=$(podman image inspect --format '{{.Created.Unix}}' "${IMAGE}" 2>/dev/null || echo 0)
if [ "${have}" != "${want}" ] || [ $(( $(date +%s) - created )) -gt $((7 * 86400)) ]; then
  echo "building ${IMAGE}"
  podman build -q --pull=newer --label "pulsar.containerfile=${want}" -t "${IMAGE}" "${ctx}" >/dev/null
  podman image prune -f >/dev/null
fi
exec podman run --rm -v "${REPO}:/opt/pulsar:Z" -w /opt/pulsar "${IMAGE}" ./scripts/check.sh
