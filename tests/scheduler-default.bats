#!/usr/bin/env bats
# Pulsar's scheduler: the kernel's own (EEVDF) by default, scx.service opt-in.
#
# Decided 2026-11-03 on a 275HX (8 P + 16 E-cores): the shipped scx_bpfland
# kept GNOME Shell on E-cores and animations jumped to their end; EEVDF kept it
# on P-cores at the same package power. Turning the scheduler back on by
# default is one `systemctl enable` line or one preset line, and nothing
# would say so, so the default is pinned here.
#
# The checks that report on the scheduler have to agree with that default:
# EEVDF is the healthy state, and only an opt-in that failed to attach may
# warn. A boot check or doctor that warned on every default machine would
# teach everyone to ignore both.

CHECK="system_files/usr/lib/greenboot/check/wanted.d/20-scx-scheduler.sh"

setup() {
    cd "${BATS_TEST_DIRNAME}/.." || exit 1
    PULSAR="$PWD/cli/pulsar"
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export PATH="${STUB}:${PATH}"
    # a fake /sys/kernel/sched_ext and build marker
    export PULSAR_SCHED_EXT="${BATS_TEST_TMPDIR}/sched_ext"
    export PULSAR_SCX_SUPPORTED="${BATS_TEST_TMPDIR}/scx-supported"
    # systemctl answers is-enabled from $SCX_ENABLED; journalctl says nothing
    cat > "${STUB}/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
    is-enabled) echo "${SCX_ENABLED:-disabled}"; [ "${SCX_ENABLED:-disabled}" = enabled ] ;;
    is-active)  echo inactive; exit 3 ;;
    *)          exit 0 ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "${STUB}/journalctl"
    chmod +x "${STUB}/systemctl" "${STUB}/journalctl"
    # doctor's manifest and disk checks need something to read
    export PULSAR_MANIFEST="${BATS_TEST_TMPDIR}/manifest.json"
    echo '{"image":"pulsar","version":"1","components":{}}' > "$PULSAR_MANIFEST"
}

# sched_ext <state> [ops]: what the kernel reports
sched_ext() {
    mkdir -p "$PULSAR_SCHED_EXT/root"
    echo "$1" > "$PULSAR_SCHED_EXT/state"
    [ -z "${2:-}" ] || echo "$2" > "$PULSAR_SCHED_EXT/root/ops"
}

doctor_scheduler() {
    run "$PULSAR" doctor scheduler --json
    STATUS=$(echo "$output" | jq -r '.checks[] | select(.id=="scheduler") | .status')
    SUMMARY=$(echo "$output" | jq -r '.checks[] | select(.id=="scheduler") | .summary')
}

# --- the default ------------------------------------------------------------

@test "the image does not enable scx.service" {
    # commands only: the comments explain how to opt in
    ! grep -v '^[[:space:]]*#' Containerfile | grep -Eq 'systemctl (--[a-z-]+ )*enable[^|&;]*scx\.service' || false
}

@test "the preset does not enable scx.service" {
    ! grep -Eq '^enable scx\.service' system_files/usr/lib/systemd/system-preset/50-pulsar.preset || false
}

@test "the manifest names EEVDF as the scheduler, whatever the kernel can load" {
    grep -q -- '--arg scheduler "eevdf"' Containerfile
}

@test "the opt-in unit is still there to opt into" {
    grep -q '^ExecStart=/usr/bin/scx_' system_files/usr/lib/systemd/system/scx.service
    grep -q '^WantedBy=multi-user.target' system_files/usr/lib/systemd/system/scx.service
}

# --- greenboot ----------------------------------------------------------------

@test "greenboot: default machine on EEVDF is healthy" {
    sched_ext disabled; touch "$PULSAR_SCX_SUPPORTED"
    run bash "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Pulsar's default"* ]]
}

@test "greenboot: a kernel without sched_ext is healthy" {
    run bash "$CHECK"
    [ "$status" -eq 0 ]
}

@test "greenboot: an opt-in that attached is healthy and named" {
    sched_ext enabled bpfland_1.1.4_x86_64; touch "$PULSAR_SCX_SUPPORTED"
    SCX_ENABLED=enabled run bash "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bpfland_1.1.4"* ]]
}

@test "greenboot: an opt-in that did not attach warns" {
    sched_ext disabled; touch "$PULSAR_SCX_SUPPORTED"
    SCX_ENABLED=enabled run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"enabled but sched_ext is 'disabled'"* ]]
}

@test "greenboot: an opt-in on a kernel that cannot load a scheduler is not a fault" {
    sched_ext disabled
    SCX_ENABLED=enabled run bash "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot load a BPF scheduler"* ]]
}

# --- pulsar doctor ------------------------------------------------------------

@test "doctor: default machine on EEVDF is ok and says how to opt in" {
    sched_ext disabled; touch "$PULSAR_SCX_SUPPORTED"
    doctor_scheduler
    [ "$STATUS" = ok ]
    [[ "$SUMMARY" == *"Pulsar's default"* ]]
    [[ "$output" == *"systemctl enable --now scx.service"* ]]
}

@test "doctor: an opt-in that attached is ok and named" {
    sched_ext enabled bpfland_1.1.4_x86_64; touch "$PULSAR_SCX_SUPPORTED"
    SCX_ENABLED=enabled doctor_scheduler
    [ "$STATUS" = ok ]
    [[ "$output" == *"bpfland_1.1.4"* ]]
}

@test "doctor: an opt-in that did not attach warns" {
    sched_ext disabled; touch "$PULSAR_SCX_SUPPORTED"
    SCX_ENABLED=enabled doctor_scheduler
    [ "$STATUS" = warn ]
}

@test "doctor: an opt-in on a kernel that cannot load a scheduler is ok" {
    sched_ext disabled
    SCX_ENABLED=enabled doctor_scheduler
    [ "$STATUS" = ok ]
    [[ "$SUMMARY" == *"cannot load a BPF scheduler"* ]]
}
