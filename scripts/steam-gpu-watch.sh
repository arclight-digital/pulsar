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
# process as a crash, and Steam's browser process keeps that count for as
# long as it runs (cef_log.txt, 2026-10-11: a crash on 10-09 was still number
# 1 when the next came two days later). On the third, Steam relaunches its
# whole UI. So this restarts the process only when the stall is observed,
# never as a precaution.
#
# WHAT "STUCK" MEANS. The GPU process is the steamwebhelper that owns a
# VizCompositorTh thread (it is forked from a zygote, so its command line
# says --type=zygote, not --type=gpu-process). Its main thread is stuck when,
# on STALL_TICKS consecutive one-second samples, it is inside a drm_syncobj
# wait AND has made no more than MAX_SWITCHES voluntary context switches in
# all that time. The driver's wait times out after 5 s and goes straight back
# in, so the stall wakes about once per 5 s and ten seconds of it costs a
# switch or two. An idle Steam sits in poll, not here.
#
# Two healthy states wait there too. A frame loop on screen waits a few
# milliseconds at a time and switches dozens of times a second. A Steam window
# that is not on screen gets one frame a second from Xwayland, so its GPU
# process spends nearly all its time in this wait and switches only 2-8 times
# a second (cherenkov, 2026-10-11: the release point it waited on moved on
# every second). The first version allowed 2 switches a second for 3 s, and
# that background loop fell under it now and then: eight restarts in one
# afternoon with no stall, three of which relaunched the whole Steam UI.
#
# Drop this when an NVIDIA or Xwayland release no longer stalls after resume:
# stop shipping the unit, then check that the window repaints after a lid close.
set -uo pipefail
shopt -s nullglob

PROC=${PULSAR_PROC:-/proc}
INTERVAL=${PULSAR_STEAM_WATCH_INTERVAL:-1}
IDLE_INTERVAL=${PULSAR_STEAM_WATCH_IDLE:-10}
# Two of the driver's 5 s wait timeouts.
STALL_TICKS=${PULSAR_STEAM_WATCH_TICKS:-10}
# Switches allowed across those STALL_TICKS samples: the wait's own timeout
# wakes it twice in ten seconds, and this allows twice that. Off screen, the
# frame loop makes 20 or more.
MAX_SWITCHES=4
COOLDOWN=${PULSAR_STEAM_WATCH_COOLDOWN:-30}
# Tests bound the loop; 0 is forever.
MAX_LOOPS=${PULSAR_STEAM_WATCH_LOOPS:-0}

log() { echo "steam-gpu-watch: $*"; }

# Builtins only below: this samples every second for the whole session.
# /proc/PID/wchan has no trailing newline, so read fails at EOF with the
# value already read; only an empty read is a failure.
read_line() { local _l=""; IFS= read -r _l 2>/dev/null < "$1" || [ -n "$_l" ] || return 1; printf -v "$2" '%s' "$_l"; }

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

# since: the switch count when the current run of quiet waiting began.
gpu="" since="" stalled=0 loops=0
while :; do
    if [ "$MAX_LOOPS" -gt 0 ]; then
        loops=$((loops + 1)); [ "$loops" -le "$MAX_LOOPS" ] || exit 0
    fi
    if [ -z "$gpu" ] || ! is_gpu_process "$gpu"; then
        gpu="" since="" stalled=0
        find_gpu_process || { sleep "$IDLE_INTERVAL"; continue; }
    fi
    wchan="" sw=""
    read_line "$PROC/$gpu/task/$gpu/wchan" wchan
    switches "$gpu" sw
    if [[ $wchan == drm_syncobj* ]] && [ -n "$sw" ]; then
        if [ -n "$since" ] && [ $((sw - since)) -le "$MAX_SWITCHES" ]; then
            stalled=$((stalled + 1))
        else
            # Out of budget: a frame got through. Start again from here.
            since=$sw stalled=0
        fi
    else
        since="" stalled=0
    fi
    if [ "$stalled" -ge "$STALL_TICKS" ]; then
        log "Steam's GPU process $gpu has been stuck in an explicit-sync wait for ${stalled}s ($((sw - since)) wakeups); restarting it"
        kill "$gpu" 2>/dev/null || log "could not signal $gpu"
        gpu="" since="" stalled=0
        sleep "$COOLDOWN"
        continue
    fi
    sleep "$INTERVAL"
done
