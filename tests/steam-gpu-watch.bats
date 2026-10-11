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
# same place is left alone; a GPU process that is merely idle is too; and
# another Chromium app's GPU process (Discord, a browser), which owns a
# VizCompositorTh just the same, is never Steam's however stuck it looks.
# Chromium treats every kill as a crash and falls back to software after a
# few, so a false positive is not harmless.
#
# And the count itself: only CONSECUTIVE stalled samples add up, a GPU
# process CEF starts in place of the old one starts from zero, and after a
# restart the watcher waits out its cooldown and wants a fresh stall before
# it acts again.

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
    # -9: one of these ignores TERM. The wait reaps it without a job notice.
    if [ -n "${VICTIM2:-}" ]; then
        kill -9 "$VICTIM2" 2>/dev/null || true
        wait "$VICTIM2" 2>/dev/null || true
    fi
}

# fake_proc PID COMM MAIN_WCHAN SWITCHES [THREAD_COMM...]
#
# Checked against a running Steam (Flatpak, NVIDIA 615.71.09, kernel 7.2.8)
# with od -c: comm and every task's comm end in a newline; wchan does not;
# status is "Key:\tvalue" lines. The GPU process is the steamwebhelper with a
# VizCompositorTh thread, and a stalled one waits in
# drm_syncobj_array_wait_timeout.constprop.0 (the symbol in /proc/kallsyms).
fake_proc() {
    local pid=$1 comm=$2 wchan=$3 sw=$4 t n=1
    shift 4
    mkdir -p "$PULSAR_PROC/$pid/task/$pid"
    echo "$comm" > "$PULSAR_PROC/$pid/comm"
    echo "$comm" > "$PULSAR_PROC/$pid/task/$pid/comm"
    # The kernel writes wchan with no trailing newline. An echo here hid a
    # watcher that read it as empty and never fired on real hardware.
    printf '%s' "$wchan" > "$PULSAR_PROC/$pid/task/$pid/wchan"
    printf 'Name:\t%s\nvoluntary_ctxt_switches:\t%s\nnonvoluntary_ctxt_switches:\t7\n' \
        "$comm" "$sw" > "$PULSAR_PROC/$pid/task/$pid/status"
    for t in "$@"; do
        mkdir -p "$PULSAR_PROC/$pid/task/$((pid + n))"
        echo "$t" > "$PULSAR_PROC/$pid/task/$((pid + n))/comm"
        n=$((n + 1))
    done
}

# set_switches PID N: the main thread's voluntary context switches so far
set_switches() {
    printf 'Name:\tsteamwebhelper\nvoluntary_ctxt_switches:\t%s\nnonvoluntary_ctxt_switches:\t7\n' \
        "$2" > "$PULSAR_PROC/$1/task/$1/status"
}

# The watcher's only clock is sleep, once per sample. This one takes no time,
# records what it was asked to wait, and after sample N runs step N, if a test
# wrote one, so each change to the fake /proc lands between two known samples
# instead of racing a background writer.
fake_clock() {
    CLOCK="${BATS_TEST_TMPDIR}/clock"
    mkdir -p "$CLOCK/bin"
    cat > "$CLOCK/bin/sleep" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$CLOCK/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CLOCK/n"
echo "$1" >> "$CLOCK/slept"
[ ! -f "$CLOCK/step.$n" ] || . "$CLOCK/step.$n"
EOF
    chmod +x "$CLOCK/bin/sleep"
    export CLOCK PATH="$CLOCK/bin:$PATH"
    export -f fake_proc set_switches
}

# step N COMMANDS: run COMMANDS after the watcher's Nth sample
step() { printf '%s\n' "$2" > "$CLOCK/step.$1"; }

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
    # its real threads: an IO thread and a tile worker, no viz compositor
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 50 \
        Chrome_IOThread CompositorTileW
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    alive
}

@test "a renderer, whose compositor thread is not the viz compositor, is never the target" {
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 50 \
        Chrome_ChildIOT Compositor GpuMemoryThread
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    alive
}

@test "another Chromium app's GPU process is never the target, however stuck" {
    fake_proc "$VICTIM" Discord drm_syncobj_array_wait_timeout.constprop.0 50 \
        Chrome_ChildIOT VizCompositorTh
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
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 0 VizCompositorTh
    fake_clock
    # dozens of switches between every two samples, as a healthy loop makes
    for n in 1 2 3 4 5 6 7; do step "$n" "set_switches $VICTIM $((n * 60))"; done
    run "$SCRIPT"
    [ -z "$output" ]
    alive
}

@test "only consecutive stalled samples count: progress in between starts the count again" {
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 1000 VizCompositorTh
    fake_clock
    # a quiet second, then 60 switches, over and over: never three quiet
    # seconds in a row, so never the stall
    step 2 "set_switches $VICTIM 1060"
    step 4 "set_switches $VICTIM 1120"
    step 6 "set_switches $VICTIM 1180"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    alive
}

@test "a GPU process CEF starts in place of the old one is counted from zero" {
    # The old one went quiet for two samples and was replaced. The new one
    # has a low switch count of its own and a busy frame loop; held against
    # the old one's count it would look stalled on its first sample.
    sleep 300 & VICTIM2=$!
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 136053 VizCompositorTh
    fake_clock
    step 3 "rm -rf '$PULSAR_PROC/$VICTIM'
fake_proc $VICTIM2 steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 10 VizCompositorTh"
    for n in 4 5 6 7; do step "$n" "set_switches $VICTIM2 $((10 + (n - 3) * 60))"; done
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    kill -0 "$VICTIM2"
}

@test "after a restart it waits out the cooldown before it looks again" {
    fake_proc "$VICTIM" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 136053 VizCompositorTh
    export PULSAR_STEAM_WATCH_INTERVAL=1 PULSAR_STEAM_WATCH_IDLE=10 PULSAR_STEAM_WATCH_COOLDOWN=30
    fake_clock
    run "$SCRIPT"
    [[ "$output" == *"restarting it"* ]]
    # three one-second samples to see the stall, then the cooldown
    [ "$(head -4 "$CLOCK/slept" | paste -sd' ')" = "1 1 1 30" ]
    # one wait per sample: the cooldown takes the interval's place, it is
    # not a wait on top of it
    [ "$(wc -l < "$CLOCK/slept")" -eq "$PULSAR_STEAM_WATCH_LOOPS" ]
}

@test "a GPU process that outlives its restart is not restarted again without a fresh stall" {
    # It ignores the TERM and stays stuck. The next restart has to be earned
    # by three stalled samples of its own, not inherited from the last one.
    ( trap '' TERM; exec sleep 300 ) & VICTIM2=$!
    fake_proc "$VICTIM2" steamwebhelper drm_syncobj_array_wait_timeout.constprop.0 136053 VizCompositorTh
    fake_clock
    PULSAR_STEAM_WATCH_LOOPS=6 run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'restarting it' <<<"$output")" -eq 1 ]
    kill -0 "$VICTIM2"
}

@test "with no Steam running it does nothing" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
