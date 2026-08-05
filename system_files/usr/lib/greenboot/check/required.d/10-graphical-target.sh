#!/usr/bin/bash
# REQUIRED: the desktop actually came up.
#
# This is the check that earns greenboot a place on a workstation image. A
# deployment that boots to a black screen or a dead GDM is precisely the
# failure a manual `bootc rollback` cannot repair -- you cannot type the
# command without a session to type it in. Three red boots and greenboot
# takes the machine back to the previous deployment on its own.
#
# Polls rather than sampling once: greenboot-healthcheck.service is ordered
# Before=boot-complete.target and only After=network-online.target, so on a
# cold boot it can and does win the race against graphical.target.
set -euo pipefail

TIMEOUT=${PULSAR_GRAPHICAL_TIMEOUT:-120}
INTERVAL=5
elapsed=0

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if systemctl is-active --quiet graphical.target; then
        echo "graphical.target is active (after ${elapsed}s)"
        exit 0
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

echo "graphical.target did not become active within ${TIMEOUT}s"
echo "failed units at time of check:"
systemctl list-units --failed --no-legend --no-pager || true
exit 1
