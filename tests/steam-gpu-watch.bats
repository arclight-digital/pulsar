#!/usr/bin/env bats
# Tests for scripts/steam-gpu-watch.sh.
#
# The bug these exist for: on 2026-10-01, after a resume, cherenkov's Steam
# window stopped repainting. CEF's GPU process sat in a drm_syncobj timeline
# wait for a buffer release Xwayland never sent, and killing that one process
# fixed the window at once.
#
# Pinned here: only the GPU process is touched (the steamwebhelper that owns
# VizCompositorTh, not the browser process that also maps NVIDIA GL); only a
# wait that makes no progress counts, so a busy frame loop that waits in the
# same place is left alone; and a GPU process that is merely idle is too.
# Chromium treats every kill as a crash and falls back to software after a
# few, so a false positive is not harmless.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/steam-gpu-watch.sh"
    export PULSAR_PROC="${BATS_TEST_TMPDIR}/proc"
    export PULSAR_STEAM_WATCH_INTERVAL=0 PULSAR_STEAM_WATCH_IDLE=0
    export PULSAR_STEAM_WATCH_COOLDOWN=0 PULSAR_STEAM_WATCH_LOOPS=8
    mkdir -p "$PULSAR_PROC"
    sleep 300 & VICTIM=$!
}

teardown() {
    kill "$VICTIM" 2>/dev/null || true
    [ -z "${WRITER:-}" ] || kill "$WRITER" 2>/dev/null || true
}

# fake_proc PID COMM MAIN_WCHAN SWITCHES [THREAD_COMM...]
fake_proc() {
    local pid=$1 comm=$2 wchan=$3 sw=$4 t n=1
    shift 4
    mkdir -p "$PULSAR_PROC/$pid/task/$pid"
    echo "$comm" > "$PULSAR_PROC/$pid/comm"
    echo "$comm" > "$PULSAR_PROC/$pid/task/$pid/comm"
    echo "$wchan" > "$PULSAR_PROC/$pid/task/$pid/wchan"
    printf 'Name:\t%s\nvoluntary_ctxt_switches:\t%s\nnonvoluntary_ctxt_switches:\t7\n' \
        "$comm" "$sw" > "$PULSAR_PROC/$pid/task/$pid/status"
    for t in "$@"; do
        mkdir -p "$PULSAR_PROC/$pid/task/$((pid + n))"
        echo "$t" > "$PULSAR_PROC/$pid/task/$((pid + n))/comm"
        n=$((n + 1))
    done
}

alive() { kill -0 "$VICTIM" 2>/dev/null; }

@test "a GPU process stuck in a syncobj wait is restarted" {
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 136053 \
        Chrome_ChildIOT VizCompositorTh
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"restarting it"* ]]
    sleep 0.2
    ! alive
}

@test "the browser process is never the target, even when it waits there" {
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout 50 Chrome_ChildIOT
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    alive
}

@test "an idle GPU process is left alone" {
    fake_proc "$VICTIM" steamwebhelper poll_schedule_timeout.constprop.0 10 VizCompositorTh
    run "$SCRIPT"
    [ -z "$output" ]
    alive
}

@test "a busy frame loop that waits in the same place is left alone" {
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout 0 VizCompositorTh
    st="$PULSAR_PROC/$VICTIM/task/$VICTIM/status"
    ( i=0; while :; do i=$((i + 60)); printf 'voluntary_ctxt_switches:\t%s\n' "$i" > "$st.n"; mv "$st.n" "$st"; sleep 0.02; done ) &
    WRITER=$!
    PULSAR_STEAM_WATCH_INTERVAL=0.1 run "$SCRIPT"
    [ -z "$output" ]
    alive
}

@test "with no Steam running it does nothing" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
