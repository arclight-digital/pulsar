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
# reopened. The notification names those apps and offers a "Reopen them"
# button. Nothing is closed unless that is clicked: the apps may be holding
# work (a game in Steam, a half-written message), and closing them is the
# user's call. The button closes each one and starts it again; a background
# helper with no launcher (NautilusPreviewer) is only closed, and starts again
# the next time it is asked for.
set -uo pipefail

UNIT=xdg-document-portal.service
TIMEOUT=${PULSAR_DOC_PORTAL_TIMEOUT:-15}
MOUNT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/doc
MOUNTINFO=${PULSAR_MOUNTINFO:-/proc/self/mountinfo}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/pulsar
# Where Flatpak exports the launchers of user and system installs.
EXPORTS=${PULSAR_FLATPAK_EXPORTS:-${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/exports/share/applications /var/lib/flatpak/exports/share/applications}

log() { echo "doc-portal-watch: $*"; }

# com.valvesoftware.Steam com.discordapp.Discord -> "Steam, Discord"
short_names() { printf '%s\n' "$@" | sed 's/.*\.//' | paste -sd, - | sed 's/,/, /g'; }

launcher() {
    local d
    for d in $EXPORTS; do
        [ -e "$d/$1.desktop" ] && { echo "$d/$1.desktop"; return 0; }
    done
    return 1
}

running() { flatpak ps --columns=application 2>/dev/null | grep -x "$1" >/dev/null; }

# --offer APP...: the notification and its button. Run as a transient unit of
# its own, because the click can come long after this check has finished.
offer() {
    local answer app desktop n
    answer=$(notify-send --app-name=Pulsar --icon=dialog-warning --action=reopen="Reopen them" \
        "Opening files was stuck, and is fixed now" \
        "$(short_names "$@") can't open or save files until they're reopened.") || return 0
    [ "$answer" = reopen ] || return 0
    for app in "$@"; do
        log "reopening $app"
        flatpak kill "$app" 2>/dev/null
        # Gone before it starts again, or the launch only opens another
        # window in the old sandbox, which still has the dead mount.
        for ((n = 0; n < 20; n++)); do
            running "$app" || break
            sleep "${PULSAR_DOC_PORTAL_POLL:-0.5}"
        done
        if running "$app"; then log "$app did not close; not starting it again"; continue; fi
        if desktop=$(launcher "$app"); then gio launch "$desktop"; fi
    done
}
if [ "${1:-}" = --offer ]; then shift; offer "$@"; exit 0; fi

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
mapfile -t apps < <(flatpak ps --columns=application 2>/dev/null | sort -u)

systemctl --user kill --signal=SIGKILL "$UNIT"
systemctl --user restart "$UNIT" || { log "the portal did not come back"; exit 1; }
log "restarted"

# KillMode=process: the apps the button starts again are children of this
# unit until Flatpak moves them into scopes of their own, and must outlive it.
if [ ${#apps[@]} -gt 0 ] && command -v notify-send >/dev/null; then
    systemd-run --user --collect --quiet -p KillMode=process \
        --unit="pulsar-doc-portal-reopen-$(date +%s)" \
        -- "$(realpath "$0")" --offer "${apps[@]}" || log "could not offer to reopen ${apps[*]}"
fi
