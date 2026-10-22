#!/usr/bin/env bash
# doc-portal-watch.sh -- restart the document portal when it stops answering.
# Run once a minute by pulsar-doc-portal-watch.timer, in the user's session.
#
# WHY THIS EXISTS. xdg-document-portal is how a Flatpak app gets at a file
# the user opened with it: Nautilus or a file chooser registers the file, and
# the app reads it through the portal's FUSE mount at $XDG_RUNTIME_DIR/doc.
# On cherenkov (xdg-desktop-portal 1.22.1) it has broken two ways, and either
# way every Flatpak app that is handed a file hangs (Loupe, NautilusPreviewer):
#
#   1. The mount vanishes while the service stays up (2026-10-01, 10-03).
#   2. It deadlocks on itself (2026-10-04, 10-21, the same stack both times).
#      document_add_full takes the document lock, app_has_file_access spawns
#      a helper and runs a nested main loop until it exits, that loop
#      dispatches a second AddFull, and the second document_add_full waits on
#      the lock the first one holds. The mount stays, every read of it hangs,
#      and the service ignores SIGTERM.
#
# Restarting the service clears both, so this does that, and only that. The
# deadlock is upstream's; drop this once a portal release no longer hangs.
#
# HOW IT TELLS. Only a running portal is judged: it is D-Bus activated, and a
# portal nothing has asked for yet is not broken. Then, in order:
#   - the mount is gone from mountinfo. Read from mountinfo, never from the
#     mount itself, which is what hangs.
#   - GetMountPoint gets no answer within TIMEOUT seconds. Method calls run
#     on the portal's main thread, the thread the deadlock holds, so this
#     hangs exactly when file access does, and costs nothing when it works.
#
# HOW IT RESTARTS. SIGKILL, then start. A stop sends TERM, which the
# deadlocked portal ignores, waits out the 45 s abort timeout and leaves a
# core dump behind. Before the kill it saves the hung portal's stacks (if
# eu-stack is there) for an upstream report.
#
# THE COST. A Flatpak app already running when the portal restarts keeps its
# view of the old mount, which now fails with "Transport endpoint is not
# connected": it cannot open or save files through the portal until it is
# reopened. The notification names those apps.
set -uo pipefail

UNIT=xdg-document-portal.service
TIMEOUT=${PULSAR_DOC_PORTAL_TIMEOUT:-15}
MOUNT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/doc
MOUNTINFO=${PULSAR_MOUNTINFO:-/proc/self/mountinfo}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/pulsar

log() { echo "doc-portal-watch: $*"; }

systemctl --user is-active --quiet "$UNIT" || exit 0

# Field 5 of mountinfo is the mount point.
reason=""
if ! awk -v m="$MOUNT" '$5 == m { found = 1 } END { exit !found }' "$MOUNTINFO"; then
    reason="its mount at $MOUNT is gone"
elif ! timeout -k 2 "$TIMEOUT" gdbus call --session \
        --dest org.freedesktop.portal.Documents \
        --object-path /org/freedesktop/portal/documents \
        --method org.freedesktop.portal.Documents.GetMountPoint >/dev/null 2>&1; then
    reason="it did not answer GetMountPoint within ${TIMEOUT}s"
fi
[ -n "$reason" ] || exit 0

log "restarting $UNIT: $reason"

pid=$(systemctl --user show -p MainPID --value "$UNIT")
if command -v eu-stack >/dev/null && [ "${pid:-0}" -gt 0 ]; then
    mkdir -p "$STATE"
    stacks="$STATE/doc-portal-hang-$(date +%Y%m%d-%H%M%S).txt"
    timeout -k 2 30 eu-stack -p "$pid" > "$stacks" 2>&1 && log "its stacks are in $stacks"
fi

# Read before the restart: these are the apps holding the old mount.
apps=$(flatpak ps --columns=application 2>/dev/null | sort -u | sed 's/.*\.//' | paste -sd, - | sed 's/,/, /g')

systemctl --user kill --signal=SIGKILL "$UNIT"
systemctl --user restart "$UNIT" || { log "the portal did not come back"; exit 1; }
log "restarted"

if [ -n "$apps" ] && command -v notify-send >/dev/null; then
    notify-send --app-name=Pulsar --icon=dialog-warning \
        "Opening files was stuck, and is fixed now" \
        "Reopen ${apps} to open or save files in them again." || true
fi
