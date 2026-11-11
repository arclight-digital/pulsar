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
# reopened. The notification names those apps, by their launchers' names, and
# offers a "Quit and Reopen" button. Nothing is closed unless that is
# clicked: the apps may be holding work (a game in Steam, a half-written
# message), and closing them is the user's call.
#
# The button asks each app still running to quit through its own "quit"
# action (org.freedesktop.Application.ActivateAction on the app's bus name),
# which is what the app's Quit command and the dash's Quit both run, so an app
# with unsaved work asks about it as it always does. It waits up to QUIT_WAIT
# seconds, starts again each one that quit, and names the rest in a second
# notification for the user to close: those either did not quit (a save
# prompt may be up) or have no quit action to call (Steam, Electron apps).
# Nothing is ever killed. A force-quit button for the rest would lose the very
# work a save prompt is guarding, and closing an app by hand costs the user
# one click more. One the user closed meanwhile stays closed, and a
# background helper with no launcher (NautilusPreviewer) is only asked to
# quit, and starts again the next time it is asked for.
set -uo pipefail

UNIT=xdg-document-portal.service
TIMEOUT=${PULSAR_DOC_PORTAL_TIMEOUT:-15}
MOUNT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/doc
MOUNTINFO=${PULSAR_MOUNTINFO:-/proc/self/mountinfo}
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/pulsar
QUIT_WAIT=${PULSAR_DOC_PORTAL_QUIT_WAIT:-20}
# Where Flatpak exports the launchers of user and system installs.
EXPORTS=${PULSAR_FLATPAK_EXPORTS:-${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/exports/share/applications /var/lib/flatpak/exports/share/applications}

log() { echo "doc-portal-watch: $*"; }

# "Steam" "Image Viewer" -> "Steam, Image Viewer"
join() { local out="" x; for x in "$@"; do out+="${out:+, }$x"; done; printf '%s' "$out"; }

launcher() {
    local d
    for d in $EXPORTS; do
        [ -e "$d/$1.desktop" ] && { echo "$d/$1.desktop"; return 0; }
    done
    return 1
}

# The app's Name= from its launcher, in the user's language when the launcher
# has it (Name[de_DE], then Name[de], as the desktop entry spec looks them up),
# else the Flatpak ID: a helper with no launcher (NautilusPreviewer).
display_name() {
    local desktop name=""
    if desktop=$(launcher "$1"); then
        name=$(awk -v loc="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" '
            BEGIN {
                l = loc; mod = ""; country = ""
                if ((i = index(l, "@"))) { mod = substr(l, i + 1); l = substr(l, 1, i - 1) }
                if ((i = index(l, "."))) l = substr(l, 1, i - 1)
                lang = l
                if ((i = index(l, "_"))) { lang = substr(l, 1, i - 1); country = substr(l, i + 1) }
                n = 0
                if (lang != "" && lang != "C" && lang != "POSIX") {
                    if (country != "" && mod != "") key[++n] = "Name[" lang "_" country "@" mod "]"
                    if (country != "") key[++n] = "Name[" lang "_" country "]"
                    if (mod != "") key[++n] = "Name[" lang "@" mod "]"
                    key[++n] = "Name[" lang "]"
                }
                key[++n] = "Name"
            }
            /^\[/ { group = $0; next }
            group == "[Desktop Entry]" && (i = index($0, "=")) {
                k = substr($0, 1, i - 1); sub(/[ \t]+$/, "", k)
                v = substr($0, i + 1); sub(/^[ \t]+/, "", v)
                if (!(k in val)) val[k] = v
            }
            END { for (j = 1; j <= n; j++) if (val[key[j]] != "") { print val[key[j]]; exit } }
        ' "$desktop")
    fi
    printf '%s\n' "${name:-$1}"
}

# The apps' names, alphabetical, for a notification.
names() {
    local a
    local -a out=()
    mapfile -t out < <(for a in "$@"; do display_name "$a"; done | sort -f)
    join "${out[@]}"
}

running() { flatpak ps --columns=application 2>/dev/null | grep -x "$1" >/dev/null; }

# Ask APP to quit through its own "quit" action, the one its Quit command
# runs. Fails when there is nobody to ask: the app owns no bus name of its
# own ID (Steam, Electron apps), or has no quit action. A call that times out
# was asked: an app that puts up a modal save prompt from inside the action
# answers only once the prompt is dealt with.
ask_to_quit() {
    local err rc
    # Only an owned name: calling an unowned one could D-Bus activate the app.
    [ "$(timeout -k 2 10 gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
        "$1" 2>/dev/null)" = "(true,)" ] || return 1
    # GApplication's object path: org.gnome.Loupe -> /org/gnome/Loupe, - -> _
    err=$(timeout -k 2 10 gdbus call --session --timeout 5 --dest "$1" \
        --object-path "/$(printf '%s' "$1" | tr .- /_)" \
        --method org.freedesktop.Application.ActivateAction quit '[]' '{}' 2>&1 >/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || [[ "$err" == *"Timeout was reached"* ]]
}

# --offer APP...: the notification and its button. Run as a transient unit of
# its own, because the click can come long after this check has finished.
offer() {
    local answer app desktop deadline still
    local -A state=()
    local -a asked=() left=()
    answer=$(notify-send --app-name=Pulsar --icon=dialog-warning --action=reopen="Quit and Reopen" \
        "Pulsar restarted file access for Flatpak apps" \
        "$(names "$@") can't open or save files until reopened.") || return 0
    [ "$answer" = reopen ] || return 0
    for app in "$@"; do
        # The list is from the restart; the click can come much later. One
        # the user has closed since is not started again.
        if ! running "$app"; then log "$app is closed already; not starting it"; continue; fi
        if ask_to_quit "$app"; then
            log "asked $app to quit"; state[$app]=asked; asked+=("$app")
        else
            log "$app has no quit action to call; leaving it open"; state[$app]=open
        fi
    done
    # Gone before it starts again, or the launch only opens another window in
    # the old sandbox, which still has the dead mount. Bounded: an app with a
    # save prompt up stays until the user answers it.
    deadline=$((SECONDS + QUIT_WAIT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        still=0
        for app in "${asked[@]}"; do running "$app" && { still=1; break; }; done
        [ "$still" = 1 ] || break
        sleep "${PULSAR_DOC_PORTAL_POLL:-0.5}"
    done
    for app in "${asked[@]}"; do
        if running "$app"; then log "$app is still open; leaving it to the user"; state[$app]=open; continue; fi
        if desktop=$(launcher "$app"); then
            log "reopening $app"; gio launch "$desktop"
        else
            log "$app quit and has no launcher; not starting it"
        fi
    done
    for app in "$@"; do [ "${state[$app]:-}" = open ] && left+=("$app"); done
    [ ${#left[@]} -gt 0 ] || return 0
    notify-send --app-name=Pulsar --icon=dialog-warning \
        "Close and reopen these apps yourself" \
        "Still open: $(names "${left[@]}"). They can't open or save files until you reopen them."
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
