#!/bin/bash
# THE theme gate: one command, pass/fail. Builds the gate container FROM a
# Pulsar image and checks, against the GNOME that image carries:
#
#   1. every class/id the Shell stylesheet template targets still exists in
#      that Shell's stock stylesheet (selector drift is the one part of the
#      theme that GNOME upgrades break);
#   2. every theme passes the WCAG AA audit;
#   3. the pulsar-theme extension loads (ACTIVE);
#   4. every theme x variant, applied for real: top bar, Text Editor view,
#      libadwaita content, the checked quick toggle, sampled from a
#      screenshot and compared with the palette; the Ptyxis palette set;
#   5. revert leaves the account byte-identical and dconf-identical;
#   6. glass (the `glass` scenario): with glass and light on, on two
#      monitors at scale 1 and 1.25, every surface's glass exists and sits
#      exactly where its host does; and (`switchers`) so does the glass
#      on Alt+Tab's window thumbnails and the "not responding" dialog;
#   7. leaks (the `leaks` scenario): no stock color shows through on any
#      Shell surface in any state, and every checked quick toggle is accent;
#   8. in each of them, the Shell logged no pulsar-theme warning (glass.js
#      catches its own errors and only warns) and no JS error.
#
#   tests/theme-gate/gate.sh [image]      default ghcr.io/arclight-digital/pulsar:latest
#
# Exit 0 pass, 1 fail. Evidence in .preview/theme-gate/ (screenshots and
# gate-report.json, glass-report.json, leaks-report.json, and each run's
# Shell log as <scenario>-shell.log). Run by hand today; nightly will run
# it warn-only, and as a hard gate only when the GNOME major changes -- see
# README.md.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=${1:-ghcr.io/arclight-digital/pulsar:latest}
# GATE_IMAGE: the tag to build it as (run.sh runs the same one), so two
# gates on one host, against two images, do not overwrite each other's
export GATE_IMAGE=${GATE_IMAGE:-localhost/pulsar-theme-gate:latest}
podman build -q --build-arg IMAGE="${image}" -t "${GATE_IMAGE}" \
    -f "${here}/Containerfile" "${here}" >/dev/null || { echo "gate: could not build the gate container" >&2; exit 1; }
out=${GATE_OUT:-$(cd "${here}/../.." && pwd)/.preview/theme-gate}
rm -f "${out}/gate-report.json"
"${here}/run.sh" gate 2>"${GATE_LOG:-/tmp/theme-gate.log}" | grep -v -E '^\s*$'
rc=${PIPESTATUS[0]}
# A Shell that dies mid-run writes no report. That is a FAIL whatever the
# exit status says -- a dead gate must never read as a pass.
if [ ! -s "${out}/gate-report.json" ]; then
  echo "GATE FAIL: no gate-report.json was written (the headless Shell died?); see ${GATE_LOG:-/tmp/theme-gate.log}"
  exit 1
fi
report_ok() { python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["ok"] else 1)' "$1"; }
report_ok "${out}/gate-report.json" || rc=1
# The glass, switchers and leaks scenarios, each in a Shell of its own; the same rule:
# no report is a FAIL.
for scenario in glass switchers leaks; do
  rm -f "${out}/${scenario}-report.json"
  echo "== ${scenario}"
  "${here}/run.sh" "${scenario}" 2>>"${GATE_LOG:-/tmp/theme-gate.log}" | grep -v -E '^\s*$'
  src=${PIPESTATUS[0]}
  if [ ! -s "${out}/${scenario}-report.json" ]; then
    echo "GATE FAIL: no ${scenario}-report.json was written (the headless Shell died?); see ${GATE_LOG:-/tmp/theme-gate.log}"
    rc=1
  elif [ "${src}" -ne 0 ] || ! report_ok "${out}/${scenario}-report.json"; then
    rc=1
  fi
done
echo "THEME GATE $([ "${rc}" -eq 0 ] && echo PASS || echo FAIL)"
exit "${rc}"
