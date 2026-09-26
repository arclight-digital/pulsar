#!/bin/bash
# Run one gate scenario against a gate image built from tests/theme-gate/
# Containerfile. Nothing reaches the host session, dconf or ~/.config.
#
#   tests/theme-gate/run.sh gate|firstlogin|restart|picker [args]
#
# GATE_IMAGE picks the image (default localhost/pulsar-theme-gate:latest);
# GATE_OUT is where screenshots and gate-report.json land.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${GATE_OUT:-$(cd "${here}/../.." && pwd)/.preview/theme-gate}
mkdir -p "${out}"
exec podman run --rm --userns=keep-id --security-opt label=disable \
    -v "${here}:/gate:ro" -v "${out}:/out" -e GATE_OUT=/out -e SIZE="${SIZE:-2560x1600}" \
    "${GATE_IMAGE:-localhost/pulsar-theme-gate:latest}" /gate/session.sh "$@"
