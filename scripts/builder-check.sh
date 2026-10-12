#!/usr/bin/env bash
# check.sh on a real builder, for a commit, before it reaches main.
#
# Four nightlies in a row (2026-10-11/12) failed on tests that passed at a
# desk and in root-check.sh's container. Each fix was checked against one of
# those stand-ins, and each night found the next thing only the builder has:
# the nightly's exported environment, real root and loop devices, /tmp in
# RAM on a 16 GB VM. So the answer that counts comes from the machine: the
# build host boots a builder from the nightly's own image, plan and scripts,
# runs nightly.sh --check there (everything up to and including check.sh,
# exactly as the night does it), and reports back. See infra's
# spawn-builder.sh --kind check.
#
#   scripts/builder-check.sh            check HEAD
#   scripts/builder-check.sh <commit>   check that commit
#
# The commit goes to GitHub on a throwaway branch, check/<sha>, because the
# builder clones from there; the branch is deleted when the check ends. Only
# committed work is checked. A pass is recorded in .git/builder-checks, which
# scripts/hooks/pre-push reads: main moves only to a commit that passed here.
#
# Exit 0 passed, 1 failed, 2 could not run the check at all.
set -euo pipefail

HOST="${HELIOS_HOST:-vhelios}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

sha="$(git rev-parse --verify "${1:-HEAD}^{commit}")" || exit 2
branch="check/${sha:0:12}"
unit="pulsar-check@${sha}.service"
record="$(git rev-parse --git-common-dir)/builder-checks"

if [ -z "${1:-}" ] && ! git diff --quiet HEAD; then
  echo "note: uncommitted changes are not part of this check; it checks ${sha:0:12}" >&2
fi

on_host() { ssh -o BatchMode=yes -o ConnectTimeout=15 "${HOST}" "$@"; }

echo "pushing ${sha:0:12} to ${branch}, where the builder clones it from"
git push -q origin "${sha}:refs/heads/${branch}" || { echo "could not push ${branch}" >&2; exit 2; }
trap 'git push -q origin ":refs/heads/${branch}" 2>/dev/null || echo "note: could not delete ${branch}; delete it by hand" >&2' EXIT

# A unit that ran before keeps its last invocation id until the new run
# starts, so this run is the first id that is not that one.
previous="$(on_host "systemctl show -p InvocationID --value ${unit}")"
on_host "sudo -n systemctl reset-failed ${unit} 2>/dev/null; sudo -n systemctl start --no-block ${unit}" \
  || { echo "could not start ${unit} on ${HOST}" >&2; exit 2; }
invocation=""
for _ in $(seq 1 20); do
  invocation="$(on_host "systemctl show -p InvocationID --value ${unit}")"
  [ -n "${invocation}" ] && [ "${invocation}" != "${previous}" ] && break
  invocation=""
  sleep 1
done
[ -n "${invocation}" ] || { echo "${unit} did not start on ${HOST}" >&2; exit 2; }
echo "started ${unit} on ${HOST}; a builder takes about five minutes to boot"

# Follow this run's journal until the unit is done.
shown=0
while :; do
  state="$(on_host "systemctl show -p ActiveState --value ${unit}")"
  lines="$(on_host "sudo -n journalctl -q -o cat _SYSTEMD_INVOCATION_ID=${invocation}" || true)"
  total="$(printf '%s\n' "${lines}" | wc -l)"
  if [ "${total}" -gt "${shown}" ]; then
    printf '%s\n' "${lines}" | tail -n "+$(( shown + 1 ))"
    shown="${total}"
  fi
  case "${state}" in activating|active|reloading) sleep 15 ;; *) break ;; esac
done

result="$(on_host "systemctl show -p Result --value ${unit}")"
if [ "${result}" = success ]; then
  printf '%s passed %s\n' "${sha}" "$(date -u -Iseconds)" >> "${record}"
  echo "builder check: ${sha:0:12} PASSED"
  exit 0
fi
echo "builder check: ${sha:0:12} FAILED (${result})" >&2
exit 1
