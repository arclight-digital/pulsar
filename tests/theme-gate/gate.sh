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
#   5. revert leaves the account byte-identical and dconf-identical.
#
#   tests/theme-gate/gate.sh [image]      default ghcr.io/arclight-digital/pulsar:latest
#
# Exit 0 pass, 1 fail. Evidence in .preview/theme-gate/ (screenshots and
# gate-report.json). Run by hand today; nightly will run it warn-only, and
# as a hard gate only when the GNOME major changes -- see README.md.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=${1:-ghcr.io/arclight-digital/pulsar:latest}
podman build -q --build-arg IMAGE="${image}" -t localhost/pulsar-theme-gate:latest \
    -f "${here}/Containerfile" "${here}" >/dev/null || { echo "gate: could not build the gate container" >&2; exit 1; }
"${here}/run.sh" gate 2>"${GATE_LOG:-/tmp/theme-gate.log}" | grep -v -E '^\s*$'
exit "${PIPESTATUS[0]}"
