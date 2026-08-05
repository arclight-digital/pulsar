#!/usr/bin/bash
# REQUIRED: the desktop actually came up.
#
# This is the check that earns greenboot a place on a workstation image. A
# deployment that boots to a black screen or a dead GDM is precisely the
# failure a manual `bootc rollback` cannot repair -- you cannot type the
# command without a session to type it in. Three red boots and greenboot
# takes the machine back to the previous deployment on its own.
#
# It must NEVER wait on graphical.target. That is not a slow signal, it is an
# unreachable one, and waiting for it rebooted a working machine:
#
#   greenboot-healthcheck.service is WantedBy=multi-user.target, and
#   graphical.target Requires+After multi-user.target. So graphical.target
#   cannot activate until this script exits, and this script was waiting for
#   graphical.target to activate. `systemctl list-jobs` during the failure:
#
#       greenboot-healthcheck.service start running
#       graphical.target             start waiting
#
#   The first version polled for 120s, timed out, and rebooted -- 112 seconds
#   AFTER the user had logged into a wayland session. A health check that
#   reboots a healthy desktop is worse than no health check at all.
#
# What is true, and early: gdm.service was active 0.03s after this script
# started, and logind had a wayland greeter session 3.3s in. A graphical
# session on a seat is the honest end-state -- it means a compositor is
# actually serving a display, which is the thing you cannot recover without.
set -euo pipefail

TIMEOUT=${PULSAR_GRAPHICAL_TIMEOUT:-120}
INTERVAL=3
elapsed=0

# A logind session of type wayland or x11, in any class: `greeter` is the GDM
# login screen, `user` is a logged-in desktop. Either proves a compositor came
# up. Class is deliberately not filtered -- a machine sitting at the login
# screen has booted successfully.
graphical_session() {
    local ids id type
    ids=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}') || return 1
    [ -n "$ids" ] || return 1
    for id in $ids; do
        type=$(loginctl show-session "$id" -p Type --value 2>/dev/null) || continue
        case "$type" in
            wayland|x11) echo "$id ($type)"; return 0 ;;
        esac
    done
    return 1
}

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if session=$(graphical_session); then
        echo "graphical session present after ${elapsed}s: session ${session}"
        exit 0
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done

echo "no graphical session appeared within ${TIMEOUT}s"
echo "display-manager.service: $(systemctl is-active display-manager.service 2>&1 | head -1)"
echo "sessions known to logind:"
loginctl list-sessions --no-legend 2>&1 | head -10 || true
echo "failed units at time of check:"
systemctl list-units --failed --no-legend --no-pager 2>&1 | head -10 || true
exit 1
