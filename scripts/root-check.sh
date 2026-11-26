#!/usr/bin/env bash
# check.sh for one commit, in a container shaped like the nightly's builder,
# before that commit goes to main.
#
#   scripts/root-check.sh            check HEAD
#   scripts/root-check.sh <commit>   check that commit
#
# This is the gate scripts/hooks/pre-push reads. It used to be
# builder-check.sh, which boots a real builder for every check; each one bills
# a full hour of a dedicated 8-core instance however short the check, and in
# November that came to 116 builders and $27.66 (2026-11-26). So the check
# runs here, as close to the builder as a container gets:
#
#   - the commit itself, cloned into a fresh directory: never the working
#     tree, whose uncommitted changes the record would not describe
#   - root, on Fedora 44 with the tools the builder has
#   - 8 CPUs and 16 GB, like the builder's plan, so bats runs as many jobs as
#     it does there and runs out of memory where it would
#   - /tmp in RAM, 7.7 GB of it, like the builder's tmpfs (2026-10-12 filled
#     it, and nothing else showed that)
#   - the steps check.sh runs in containers of their own (the installer's
#     disk tests, the network speaker tests) run too, through this machine's
#     podman, so a pass covers them
#
# What it still is not: a VM with real loop devices and the night's exported
# environment (see builder-check.sh for the failures only the builder found).
# The nightly runs check.sh on a builder every night and still catches those.
#
# The container's image is built once and rebuilt when its Containerfile
# changes or it is a week old (for Fedora's updates). A pass is recorded as
# "<sha> passed <date> root-check" in the common git dir's local-checks.
#
# Exit 0 passed, 1 failed, 2 could not run the check at all.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"
IMAGE=localhost/pulsar-root-check:44
CPUS=8 MEMORY=16g TMPFS=7700m

sha="$(git rev-parse --verify "${1:-HEAD}^{commit}")" || exit 2
record="$(git rev-parse --git-common-dir)/local-checks"
if [ -z "${1:-}" ] && ! git diff --quiet HEAD; then
  echo "note: uncommitted changes are not part of this check; it checks ${sha:0:12}" >&2
fi

ctx="${REPO}/tests/root-check"
want=$(sha256sum "${ctx}/Containerfile" | cut -c1-16)
have=$(podman image inspect --format '{{index .Labels "pulsar.containerfile"}}' "${IMAGE}" 2>/dev/null || true)
created=$(podman image inspect --format '{{.Created.Unix}}' "${IMAGE}" 2>/dev/null || echo 0)
if [ "${have}" != "${want}" ] || [ $(( $(date +%s) - created )) -gt $((7 * 86400)) ]; then
  echo "building ${IMAGE}"
  podman build -q --pull=newer --label "pulsar.containerfile=${want}" -t "${IMAGE}" "${ctx}" >/dev/null || exit 2
  podman image prune -f >/dev/null
fi

# On disk, never in /tmp (RAM). --no-hardlinks: the inner containers relabel
# this copy (:Z), and a hardlinked object is the same file as the repo's own.
work=$(mktemp -d -p /var/tmp pulsar-root-check.XXXXXX)
# check.sh runs the suite a second time as nobody, who has to read the copy
chmod 755 "${work}"
service=""
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  [ -z "${service}" ] || kill "${service}" 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT
git clone -q --no-hardlinks --no-checkout "${REPO}" "${work}/pulsar" || exit 2
git -C "${work}/pulsar" checkout -q --detach "${sha}" || exit 2

# check.sh's own containers start on this machine's podman, through a socket
# that lives as long as this check. The copy sits at the same path inside and
# out, so the -v paths check.sh hands podman name it on both sides.
podman system service --time=0 "unix://${work}/podman.sock" &
service=$!
for _ in $(seq 1 50); do [ -S "${work}/podman.sock" ] && break; sleep 0.1; done
[ -S "${work}/podman.sock" ] || { echo "podman's service did not start" >&2; exit 2; }

echo "checking ${sha:0:12} as root, ${CPUS} CPUs, ${MEMORY} memory, ${TMPFS} /tmp in RAM"
# Rootless podman gets no cpuset controller, so the CPU count is an affinity
# set inside (nproc follows it) plus a quota. Each limit is read back and the
# check refuses to run without it, rather than pass on the wrong shape.
set +e
podman run --rm --security-opt label=disable \
  --cpus "${CPUS}" --memory "${MEMORY}" --memory-swap "${MEMORY}" \
  --tmpfs "/tmp:size=${TMPFS}" \
  -v "${work}:${work}" -w "${work}/pulsar" \
  -e CONTAINER_HOST="unix://${work}/podman.sock" \
  -e CPUS="${CPUS}" \
  "${IMAGE}" bash -c '
    set -eu
    exec taskset -c "0-$((CPUS - 1))" bash -c "
      set -eu
      [ \"\$(nproc)\" -eq ${CPUS} ] || { echo \"shape: nproc is \$(nproc), not ${CPUS}\" >&2; exit 2; }
      [ \"\$(cat /sys/fs/cgroup/memory.max)\" != max ] || { echo \"shape: no memory limit\" >&2; exit 2; }
      [ \"\$(stat -f -c %T /tmp)\" = tmpfs ] || { echo \"shape: /tmp is not in RAM\" >&2; exit 2; }
      podman version --format \"{{.Server.Version}}\" >/dev/null || { echo \"shape: podman unreachable\" >&2; exit 2; }
      echo \"shape: nproc \$(nproc), memory.max \$(cat /sys/fs/cgroup/memory.max), /tmp \$(df -h --output=size /tmp | tail -n 1 | tr -d \" \"), podman reachable\"
      ./scripts/check.sh
    "'
rc=$?
set -e

if [ "${rc}" -eq 0 ]; then
  printf '%s passed %s root-check\n' "${sha}" "$(date -u -Iseconds)" >> "${record}"
  echo "root check: ${sha:0:12} PASSED"
  exit 0
fi
[ "${rc}" -eq 2 ] && { echo "root check: ${sha:0:12} could not run" >&2; exit 2; }
echo "root check: ${sha:0:12} FAILED" >&2
exit 1
