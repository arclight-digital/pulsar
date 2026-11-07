#!/bin/bash
# Inside the gate container: a scratch account, a private session bus, and a
# stand-in system bus (the Shell wants logind/accounts proxies to exist;
# nothing answers on it, which the Shell tolerates). Never the host's buses.
set -euo pipefail
export HOME=/tmp/gate-home
rm -rf "$HOME"; mkdir -p "$HOME"
export XDG_CONFIG_HOME=$HOME/.config XDG_DATA_HOME=$HOME/.local/share \
       XDG_STATE_HOME=$HOME/.local/state XDG_CACHE_HOME=$HOME/.cache
export XDG_RUNTIME_DIR=/tmp/rt-$$; mkdir -m 700 "$XDG_RUNTIME_DIR"
export NO_AT_BRIDGE=1 GSK_RENDERER=cairo
dbus-daemon --session --address="unix:path=$XDG_RUNTIME_DIR/system_bus" --fork --nopidfile
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/system_bus"
# FAKE_CLOCK="2026-11-11 11:11:00": every process in the session starts at
# that wall-clock time, and it runs at a twentieth of real speed, so a full
# desktops run (about ten minutes) stays inside the same minute. Held fully
# still, the Shell's main thread span at 100% after a minute or so and never
# answered again. Only the wall clock: monotonic time runs, or no timer fires.
if [ -n "${FAKE_CLOCK:-}" ]; then
  export LD_PRELOAD=/usr/lib64/libfaketime.so.1 FAKETIME="@${FAKE_CLOCK} x0.05" FAKETIME_DONT_FAKE_MONOTONIC=1
fi
exec dbus-run-session -- python3 /gate/scenario.py "$@"
