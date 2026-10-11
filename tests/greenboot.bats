#!/usr/bin/env bats
# Tests for the greenboot health checks.
#
# These matter more than most tests in this repo: a required check that
# returns nonzero does not print a warning, it reboots the machine, and three
# of those roll the deployment back. A false negative here is indistinguishable
# from a broken OS image, from the user's side.
#
# That is not hypothetical. The first version of 10-graphical-target.sh polled
# `systemctl is-active graphical.target`, which can never succeed from inside
# greenboot-healthcheck.service -- the service is WantedBy=multi-user.target and
# graphical.target Requires+After multi-user.target, so the target it waited for
# was waiting on it. It rebooted a working laptop 112 seconds after the user had
# logged in.

setup() {
    CHECK_DIR="${BATS_TEST_DIRNAME}/../system_files/usr/lib/greenboot/check"
    GRAPHICAL="${CHECK_DIR}/required.d/10-graphical-target.sh"
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    PATH="${STUB}:${PATH}"
    export PATH
    export PULSAR_GRAPHICAL_TIMEOUT=1
}

# $1 = what `loginctl list-sessions --no-legend` prints, $2 = session Type
stub_loginctl() {
    cat > "${STUB}/loginctl" <<EOF
#!/bin/sh
case "\$1" in
  list-sessions) printf '%s' '$1'; [ -n '$1' ] && echo ;;
  show-session)  echo '$2' ;;
esac
EOF
    chmod +x "${STUB}/loginctl"
}

@test "passes when a wayland session exists" {
    stub_loginctl "  2 1000 proto seat0 -" wayland
    run bash "$GRAPHICAL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"graphical session present"* ]]
}

@test "passes at the login screen, before anyone has logged in" {
    # class=greeter is a successful boot: the machine is offering a login.
    stub_loginctl "  c1 977 gdm-greeter seat0 -" wayland
    run bash "$GRAPHICAL"
    [ "$status" -eq 0 ]
}

@test "passes on x11 as well as wayland" {
    stub_loginctl "  2 1000 proto seat0 -" x11
    run bash "$GRAPHICAL"
    [ "$status" -eq 0 ]
}

@test "fails when the only session is a tty" {
    stub_loginctl "  1 1000 proto seat0 tty2" tty
    run bash "$GRAPHICAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no graphical session"* ]]
}

@test "fails when there are no sessions at all" {
    stub_loginctl "" ""
    run bash "$GRAPHICAL"
    [ "$status" -eq 1 ]
}

@test "fails rather than crashes when loginctl is missing entirely" {
    printf '#!/bin/sh\nexit 127\n' > "${STUB}/loginctl"
    chmod +x "${STUB}/loginctl"
    run bash "$GRAPHICAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no graphical session"* ]]
}

@test "a failure explains itself instead of just exiting" {
    stub_loginctl "" ""
    run bash "$GRAPHICAL"
    [[ "$output" == *"display-manager.service"* ]]
    [[ "$output" == *"failed units"* ]]
}

@test "REGRESSION: never waits on graphical.target" {
    # The deadlock that rebooted a healthy machine. graphical.target cannot
    # activate until this script exits, so any wait on it is unsatisfiable.
    run grep -n "is-active.*graphical\.target" "$GRAPHICAL"
    [ "$status" -ne 0 ]
}

@test "every check is executable and starts with a shebang" {
    for f in "${CHECK_DIR}"/*/*.sh; do
        [ -x "$f" ] || fail "not executable: $f"
        head -1 "$f" | grep -q '^#!' || fail "no shebang: $f"
    done
}

# --- the sched_ext BTF gate -------------------------------------------------
# scripts/check-scx-btf.sh decides at build time whether the kernel being
# shipped can load a BPF scheduler at all. Both verdicts are tested against
# fixtures captured from a real `bpftool btf dump`, because a gate that has
# only ever been shown to fail proves nothing about the case that matters.

@test "BTF gate: a clean kernel passes" {
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" \
        --dump "${BATS_TEST_DIRNAME}/fixtures/btf-clean.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 carrying"* ]]
}

@test "BTF gate: a 7.2 kernel's _impl twins keep aux by design and still pass" {
    # captured from 7.2.7-200.fc44: scx_bpf_cid_curr(cid) is public and clean,
    # scx_bpf_cid_curr_impl(cid, aux) is the kernel-side twin
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" \
        --dump "${BATS_TEST_DIRNAME}/fixtures/btf-clean-impl.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 clean, 0 carrying"* ]]
}

@test "BTF gate: a public kfunc carrying aux fails even beside its _impl twin" {
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" \
        --dump "${BATS_TEST_DIRNAME}/fixtures/btf-malformed-impl.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scx_bpf_cid_curr(cid, aux)"* ]]
}

@test "BTF gate: an _impl with no public twin is malformed, not skipped" {
    grep -v "FUNC 'scx_bpf_cid_curr' " "${BATS_TEST_DIRNAME}/fixtures/btf-clean-impl.txt" > "${BATS_TEST_TMPDIR}/lone.txt"
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" --dump "${BATS_TEST_TMPDIR}/lone.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"scx_bpf_cid_curr_impl(cid, aux)"* ]]
}

@test "BTF gate: a kfunc whose prototype is missing is 'cannot determine'" {
    echo "[5] FUNC 'scx_bpf_x' type_id=99 linkage=static" > "${BATS_TEST_TMPDIR}/noproto.txt"
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" --dump "${BATS_TEST_TMPDIR}/noproto.txt"
    [ "$status" -eq 2 ]
}

@test "BTF gate: kfuncs carrying the implicit aux argument fail" {
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" \
        --dump "${BATS_TEST_DIRNAME}/fixtures/btf-malformed.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MALFORMED"* ]]
    [[ "$output" == *"scx_bpf_cpu_curr(cpu, aux)"* ]]
}

@test "BTF gate: an unreadable dump is 'cannot determine', never 'clean'" {
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" --dump /nonexistent
    [ "$status" -eq 2 ]
}

@test "BTF gate: a kernel with no scx kfuncs at all is not reported clean" {
    echo "[1] FUNC 'printk' type_id=2 linkage=static" > "${BATS_TEST_TMPDIR}/none.txt"
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" \
        --dump "${BATS_TEST_TMPDIR}/none.txt"
    [ "$status" -ne 0 ]
}

@test "BTF gate: an empty dump is 'cannot determine', not 'no sched_ext here'" {
    # Exit 1 would make the build skip the scheduler on the strength of a
    # bpftool run that produced nothing.
    : > "${BATS_TEST_TMPDIR}/empty.txt"
    run bash "${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh" --dump "${BATS_TEST_TMPDIR}/empty.txt"
    [ "$status" -eq 2 ]
}

# The running and image modes, which ask bpftool. The build runs --image.

GATE="${BATS_TEST_DIRNAME}/../scripts/check-scx-btf.sh"

# bpftool as the real one (7.2.8 host) answers `btf dump file F format raw`:
# the dump for a raw BTF file (magic 9f eb, as /sys/kernel/btf/vmlinux opens)
# or an ELF; "No such file or directory", exit 254, for a missing file; and
# "Unknown error 4001", exit 95, for anything else.
stub_bpftool() {
    export BTF_DUMP="${BATS_TEST_DIRNAME}/fixtures/btf-clean.txt"
    cat > "${STUB}/bpftool" <<'EOF'
#!/bin/sh
[ "$1 $2 $3 $5 $6" = "btf dump file format raw" ] || exit 64
f=$4
[ -r "$f" ] || { echo "Error: failed to load BTF from $f: No such file or directory" >&2; exit 254; }
case "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" in
    9feb*|7f454c46) cat "$BTF_DUMP" ;;
    *) echo "libbpf: failed to get EHDR from $f" >&2
       echo "Error: failed to load BTF from $f: Unknown error 4001" >&2
       exit 95 ;;
esac
EOF
    chmod +x "${STUB}/bpftool"
    export PULSAR_KERNEL_BTF="${BATS_TEST_TMPDIR}/btf-vmlinux"
    printf '\237\353\001\000' > "$PULSAR_KERNEL_BTF"
    export PULSAR_MODULES_DIR="${BATS_TEST_TMPDIR}/modules"
    mkdir -p "$PULSAR_MODULES_DIR"
}

# A bzImage-shaped kernel: the "MZ" and "HdrS" a real vmlinuz opens with,
# then a compressed ELF further in. Fedora's 7.2.8 vmlinuz carries zstd at
# offset 21196; gzip stands in because every builder has it, and the script
# scans for both. The ELF only has to be the size of a kernel.
fake_vmlinuz() {
    mkdir -p "${1%/*}"
    {
        printf 'MZ'; head -c 512 /dev/zero; printf 'HdrS'; head -c 1024 /dev/zero
        { printf '\177ELF'; head -c 11000000 /dev/zero; } | gzip -n -1
    } > "$1"
}

# A PATH of only these commands, so a test can take one away whatever the
# host has installed.
only_path() {
    local d="${BATS_TEST_TMPDIR}/only" c
    mkdir -p "$d"
    for c in "$@"; do ln -sf "$(command -v "$c")" "$d/$c"; done
    echo "$d"
}

@test "BTF gate: with no argument it judges the running kernel's BTF" {
    stub_bpftool
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 carrying"* ]]
    BTF_DUMP="${BATS_TEST_DIRNAME}/fixtures/btf-malformed.txt" run bash "$GATE"
    [ "$status" -eq 1 ]
}

@test "BTF gate: an unreadable running BTF is 'cannot determine', and names the file" {
    stub_bpftool
    PULSAR_KERNEL_BTF="${BATS_TEST_TMPDIR}/missing" run bash "$GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"${BATS_TEST_TMPDIR}/missing is not readable"* ]]
}

@test "BTF gate: no bpftool is 'cannot determine', and says so" {
    stub_bpftool
    run env PATH="$(only_path mktemp rm python3)" "$BASH" "$GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"bpftool is not installed"* ]]
}

@test "BTF gate --image: the kernel image's own BTF is judged" {
    stub_bpftool
    fake_vmlinuz "${PULSAR_MODULES_DIR}/7.2.8-200.fc44.x86_64/vmlinuz"
    run bash "$GATE" --image
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 carrying"* ]]
}

@test "BTF gate --image: no kernel image is 'cannot determine', and says so" {
    stub_bpftool
    run bash "$GATE" --image
    [ "$status" -eq 2 ]
    [[ "$output" == *"no ${PULSAR_MODULES_DIR}/*/vmlinuz found"* ]]
}

@test "BTF gate --image: no bpftool says so, not that the kernel lacks BTF" {
    stub_bpftool
    run env PATH="$(only_path mktemp rm python3 find sort head)" "$BASH" "$GATE" --image
    [ "$status" -eq 2 ]
    [[ "$output" == *"bpftool is not installed"* ]]
}

@test "BTF gate: no python3 is 'cannot determine' with a reason, not a bare 127" {
    run env PATH="$(only_path mktemp rm cp)" "$BASH" "$GATE" --dump "${BATS_TEST_DIRNAME}/fixtures/btf-clean.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"python3 is required"* ]]
}

@test "BTF gate: a run leaves nothing behind in TMPDIR" {
    # The extracted vmlinux and its dump live there, tens of MB a run (the
    # dump alone is 15MB on 7.2.8).
    stub_bpftool
    fake_vmlinuz "${PULSAR_MODULES_DIR}/7.2.8-200.fc44.x86_64/vmlinuz"
    mkdir -p "${BATS_TEST_TMPDIR}/tmp"
    TMPDIR="${BATS_TEST_TMPDIR}/tmp" run bash "$GATE" --image
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}
