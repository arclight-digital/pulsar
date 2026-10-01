#!/usr/bin/env bash
# steam-gpu-watch.sh -- restart the Steam client's GPU process when it is
# stuck waiting for a frame Xwayland never gives back. Run by
# pulsar-steam-gpu-watch.service for the length of the desktop session, on
# machines with the nvidia module loaded.
#
# WHY THIS EXISTS. After a suspend, the Steam window on cherenkov
# (44.20260930.2, NVIDIA 615.71.09, Xwayland 24.1.13) stopped repainting:
# resize or maximize it and the new area stayed black, then caught up after
# ~15 seconds or not at all. Steam draws its UI with CEF, and CEF's GPU
# process (a steamwebhelper) renders through NVIDIA GLX on Xwayland with
# explicit sync. On 2026-10-01 its main thread sat in
# DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT (WAIT_AVAILABLE) on one timeline point for
# minutes, re-entering the same wait every ~5 s timeout: the buffer release
# Xwayland owes it never materialised. The browser process had the new size;
# the GPU process had nowhere to draw it. Killing that one process fixed it
# at once -- CEF starts a new GPU process in under half a second and Steam
# stays open. Same class of fault as NVIDIA/open-gpu-kernel-modules#1137.
#
# WHY ONLY WHEN STUCK, NOT ON EVERY RESUME. Chromium counts a killed GPU
# process as a crash, and after a few within its window it gives up on the
# GPU and renders in software for the rest of the session. So this restarts
# the process only when the stall is observed, never as a precaution.
#
# WHAT "STUCK" MEANS. The GPU process is the steamwebhelper that owns a
# VizCompositorTh thread (it is forked from a zygote, so its command line
# says --type=zygote, not --type=gpu-process). Its main thread is stuck when,
# on STALL_TICKS consecutive one-second samples, it is inside a drm_syncobj
# wait AND has made almost no voluntary context switches since the previous
# sample. A healthy frame loop waits there too, but for a few milliseconds at
# a time and switches dozens of times a second; the stall switches once per
# 5 s timeout. An idle Steam sits in poll, not here.
#
# Drop this when an NVIDIA or Xwayland release no longer stalls after resume:
# stop shipping the unit, then check that the window repaints after a lid close.
set -uo pipefail
shopt -s nullglob

PROC=${PULSAR_PROC:-/proc}
INTERVAL=${PULSAR_STEAM_WATCH_INTERVAL:-1}
IDLE_INTERVAL=${PULSAR_STEAM_WATCH_IDLE:-10}
STALL_TICKS=${PULSAR_STEAM_WATCH_TICKS:-3}
# Switches allowed between two samples of a stalled thread: the wait's own
# timeout wakes it about every five seconds, once or twice.
MAX_SWITCHES=2
COOLDOWN=${PULSAR_STEAM_WATCH_COOLDOWN:-30}
# Tests bound the loop; 0 is forever.
MAX_LOOPS=${PULSAR_STEAM_WATCH_LOOPS:-0}

log() { echo "steam-gpu-watch: $*"; }

# Builtins only below: this samples every second for the whole session.
read_line() { local _l; IFS= read -r _l 2>/dev/null < "$1" || return 1; printf -v "$2" '%s' "$_l"; }

is_gpu_process() {
    local pid=$1 comm t
    read_line "$PROC/$pid/comm" comm && [ "$comm" = steamwebhelper ] || return 1
    for t in "$PROC/$pid"/task/*/comm; do
        read_line "$t" comm && [ "$comm" = VizCompositorTh ] && return 0
    done
    return 1
}

find_gpu_process() {
    local d
    for d in "$PROC"/[0-9]*; do
        is_gpu_process "${d##*/}" && { gpu=${d##*/}; return 0; }
    done
    return 1
}

switches() {
    local k v
    while read -r k v; do
        [ "$k" = "voluntary_ctxt_switches:" ] && { printf -v "$2" '%s' "$v"; return 0; }
    done 2>/dev/null < "$PROC/$1/task/$1/status"
    return 1
}

gpu="" last="" stalled=0 loops=0
while :; do
    if [ "$MAX_LOOPS" -gt 0 ]; then
        loops=$((loops + 1)); [ "$loops" -le "$MAX_LOOPS" ] || exit 0
    fi
    if [ -z "$gpu" ] || ! is_gpu_process "$gpu"; then
        gpu="" last="" stalled=0
        find_gpu_process || { sleep "$IDLE_INTERVAL"; continue; }
    fi
    wchan="" sw=""
    read_line "$PROC/$gpu/task/$gpu/wchan" wchan
    switches "$gpu" sw
    if [[ $wchan == drm_syncobj* ]] && [ -n "$last" ] && [ -n "$sw" ] &&
       [ $((sw - last)) -le "$MAX_SWITCHES" ]; then
        stalled=$((stalled + 1))
    else
        stalled=0
    fi
    last=$sw
    if [ "$stalled" -ge "$STALL_TICKS" ]; then
        log "Steam's GPU process $gpu has waited on one explicit-sync release for ${stalled}s; restarting it"
        kill "$gpu" 2>/dev/null || log "could not signal $gpu"
        gpu="" last="" stalled=0
        sleep "$COOLDOWN"
        continue
    fi
    sleep "$INTERVAL"
done
