#!/usr/bin/env bash
# alive-timeout.sh hold|release -- suspend mutter's frozen-window check for
# the duration of a game, and put it back afterwards.
#
# THE COMPLAINT. mutter pings every window with _NET_WM_PING and, after
# org.gnome.mutter check-alive-timeout milliseconds without an answer, offers
# to kill it. A game that blocks its main loop through a level load, a shader
# compilation pass or an unskippable cutscene does not answer, so the dialog
# appears over a fullscreen game that is working perfectly. GNOME's default is
# 5s; this image raises it to 20s in zz0-pulsar.gschema.override, which is a
# better default for everything and still not long enough for a first-launch
# UE5 shader pass.
#
# So the remaining margin is bought only while a game is actually running,
# from gamemode's [custom] start/end hooks, and handed straight back after.
# The desktop keeps a working not-responding dialog the rest of the time,
# which is the whole reason this is a hold and not a new default of 0.
#
# WHY A SCRIPT AND NOT TWO GSETTINGS ONE-LINERS IN THE INI. `gsettings reset`
# would restore the IMAGE default, silently discarding a value the user had
# deliberately set for themselves. This saves what was actually there and puts
# that back.
#
# SELF-HEALING, because a hold can leak. If gamemoded is killed outright the
# end hook never runs and the key stays at 0 -- note that an ordinary game
# CRASH does not do this, since gamemoded's reaper thread notices the dead
# client within reaper_freq seconds and runs the end hook for it. When a hold
# does leak, the state file leaks with it, and `hold` refuses to overwrite an
# existing one: the next game's release therefore restores the value saved
# before the FIRST hold, and the leak is repaired. The only lasting case is
# gamemoded dying and no game ever being played again, which costs a
# not-responding dialog and is undone by `alive-timeout.sh release`.
set -uo pipefail

SCHEMA=org.gnome.mutter
KEY=check-alive-timeout
HELD=0

STATE_DIR=${PULSAR_ALIVE_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/pulsar}
STATE="${STATE_DIR}/alive-timeout.saved"

# A failed hook must never be the reason a game does not start, so every exit
# below is 0 unless the caller asked for something meaningless.
die_soft() { echo "alive-timeout: $*" >&2; exit 0; }

command -v gsettings >/dev/null 2>&1 || die_soft "no gsettings; nothing to do"

case "${1:-}" in
hold)
    if [ -f "$STATE" ]; then
        # A previous hold leaked. Keep its saved value -- that is the one that
        # predates any hold and is the only one worth restoring.
        echo "alive-timeout: a previous hold did not release; keeping its saved value"
    else
        current=$(gsettings get "$SCHEMA" "$KEY" 2>/dev/null) || \
            die_soft "could not read ${SCHEMA} ${KEY}"
        mkdir -p "$STATE_DIR" || die_soft "could not create ${STATE_DIR}"
        printf '%s\n' "$current" > "$STATE" || die_soft "could not write ${STATE}"
    fi
    gsettings set "$SCHEMA" "$KEY" "$HELD" 2>/dev/null || \
        die_soft "could not set ${KEY}; the dialog may still appear"
    echo "alive-timeout: frozen-window check suspended for this game"
    ;;
release)
    [ -f "$STATE" ] || die_soft "nothing held; leaving ${KEY} alone"
    saved=$(cat "$STATE" 2>/dev/null)
    # Refuse to restore a value that is not a gsettings uint32. A corrupt
    # state file must not be written back into dconf.
    case "$saved" in
        "uint32 "[0-9]*) ;;
        [0-9]*)          saved="uint32 ${saved}" ;;
        *)               rm -f "$STATE"; die_soft "saved value '${saved}' is not a timeout; discarded" ;;
    esac
    if gsettings set "$SCHEMA" "$KEY" "${saved#uint32 }" 2>/dev/null; then
        rm -f "$STATE"
        echo "alive-timeout: frozen-window check restored to ${saved#uint32 }ms"
    else
        die_soft "could not restore ${KEY}; state kept at ${STATE} for the next release"
    fi
    ;;
*)
    echo "usage: alive-timeout.sh hold|release" >&2
    exit 2
    ;;
esac
