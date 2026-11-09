#!/usr/bin/env bats
# The installer's backend with every disk command stubbed: what a failed
# install says about the disk, which partitions it takes back, which drive it
# insists on, and the log it keeps. Nothing here partitions, opens, mounts or
# reads a real disk.
#
# pulsar-install-system runs its real main() with run() answering for lsblk,
# udevadm, cryptsetup, mount, efibootmgr and sfdisk from canned data,
# run_stream() standing in for bootc (it lays down a deployment's tree in the
# scratch target), and subprocess.run() recording the clean-up's umounts. Its
# disk tool is a stand-in script (PULSAR_INSTALL_DISK, the seam the bench
# uses) that prints a plan or exits as told. pulsar-install-disk runs its
# real main() with subprocess.run() answering for lsblk and systemd-repart.

bats_require_minimum_version 1.5.0

DISK=/dev/pulsar-test-disk
ROOT=11111111-1111-1111-1111-111111111111
BOOT=22222222-2222-2222-2222-222222222222
ESPU=33333333-3333-3333-3333-333333333333

setup() {
    T="$BATS_TEST_TMPDIR"
    SYS="${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system"
    TOOL="${BATS_TEST_DIRNAME}/../scripts/pulsar-install-disk"
    LAYOUTS="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/installer/repart"
    printf 'correct horse' > "$T/key"
    # the stand-in disk tool: records its argv; DISK_EXIT makes it fail
    # (2 refused, 3 failed while writing) after saying it began
    cat > "$T/disk-tool" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/disk-args"
echo "Encrypting future partition 3..." >&2
if [ -n "\${DISK_EXIT:-}" ]; then exit "\$DISK_EXIT"; fi
case " \$* " in
*" --mode alongside "*) echo '[{"type": "esp", "activity": "unchanged", "uuid": "$ESPU", "label": "EFI"},
 {"type": "basic", "activity": "unchanged", "uuid": "44444444-4444-4444-4444-444444444444", "label": "Windows"},
 {"type": "xbootldr", "activity": "create", "uuid": "$BOOT", "label": "boot"},
 {"type": "root-x86-64", "activity": "create", "uuid": "$ROOT", "label": "root"}]' ;;
*) echo '[{"type": "esp", "activity": "create", "uuid": "$ESPU", "label": "EFI"},
 {"type": "xbootldr", "activity": "create", "uuid": "$BOOT", "label": "boot"},
 {"type": "root-x86-64", "activity": "create", "uuid": "$ROOT", "label": "root"}]' ;;
esac
EOF
    chmod +x "$T/disk-tool"
}

# system MODE [ARGS...]: an install onto $DISK, encrypted, with the chosen
# drive's identity. FAIL_AT=<command prefix> makes that command fail.
# stdout: the backend's events; $T/calls: every command run(), in order.
system() {
    local mode=$1; shift
    PULSAR_INSTALL_DISK="$T/disk-tool" python3 - "$SYS" "$T" "$DISK" "$mode" "$@" <<'PY'
import importlib.machinery as M, importlib.util as U, json, os, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
T, disk, mode, extra = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
ROOT, BOOT, ESPU = ("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222",
                    "33333333-3333-3333-3333-333333333333")
m.os.geteuid = lambda: 0
m.SCRATCH = T + "/run"
calls = open(T + "/calls", "a", buffering=1)
fail_at = os.environ.get("FAIL_AT", "")
parts = [("p1", 1, m.ESP_TYPE, ESPU, "vfat", "ESPFS"), ("p2", 2, "bc13c2ff-59e6-4262-a352-b275fd6f7172", BOOT, "ext4", "BOOTFS"),
         ("p3", 3, "4f68bce3-e8cd-4db1-96e7-fbcaf984b709", ROOT, "crypto_LUKS", "LUKSUUID")]
state = {"target": None}
real_run, real_subprocess_run, real_popen = m.run, m.subprocess.run, m.subprocess.Popen

def run(*cmd, **kw):
    line = " ".join(cmd)
    calls.write(line + "\n")
    if fail_at and line.startswith(fail_at):
        raise m.Failed(f"{cmd[0]} exited 1: stopped by the test", 1)
    if cmd[0] == m.DISK_TOOL:
        return real_run(*cmd, **kw)
    if cmd[0] == "lsblk":
        return json.dumps({"blockdevices": [{"path": disk, "children": [
            {"path": disk + n, "pkname": disk, "partn": k, "parttype": t, "partuuid": u, "fstype": f, "uuid": fu}
            for n, k, t, u, f, fu in parts]}]})
    if cmd[0] == "sfdisk" and cmd[1] == "-J":
        return json.dumps({"partitiontable": {"partitions": [{"node": disk + n, "uuid": u} for n, _, _, u, _, _ in parts]}})
    if cmd[0] in ("udevadm", "cryptsetup", "mount", "umount", "efibootmgr", "sfdisk"):
        return ""
    raise SystemExit(f"unexpected command {cmd}")

def run_stream(*cmd, **kw):
    # bootc: a deployment, its stateroot's /var, a shim on the ESP
    target = cmd[-1]
    calls.write("bootc install to-filesystem " + target + "\n")
    state["target"] = target
    for d in ("ostree/deploy/default/deploy/abc.0/etc", "ostree/deploy/default/var/log", "boot/efi/EFI/fedora", "boot/grub2"):
        os.makedirs(os.path.join(target, d), exist_ok=True)
    open(os.path.join(target, "boot/efi/EFI/fedora/shimx64.efi"), "w").close()

def cleanup(cmd, *a, **k):
    # the finally block's umount and cryptsetup close, remove_made's settle;
    # each umount notes whether the installed system's log is there yet.
    # The stand-in disk tool is the one thing that really runs
    if cmd[0] == m.DISK_TOOL:
        return real_subprocess_run(cmd, *a, **k)
    if cmd[0] not in ("umount", "cryptsetup", "udevadm"):
        raise SystemExit(f"unexpected command {cmd}")
    t = state["target"]
    kept = t and os.path.exists(os.path.join(t, "ostree/deploy/default/var/log/pulsar-install.log"))
    calls.write("cleanup " + " ".join(cmd) + (" (log kept)" if kept else "") + "\n")

def popen(cmd, *a, **k):
    if cmd[0] != m.DISK_TOOL:
        raise SystemExit(f"unexpected command {cmd}")
    return real_popen(cmd, *a, **k)

m.run, m.run_stream = run, run_stream
m.subprocess.run, m.subprocess.Popen = cleanup, popen
sys.argv = ["pulsar-install-system", "--mode", mode, "--key-file", T + "/key", "--source-imgref", "a",
            "--target-imgref", "b", "--lang", "en_US.UTF-8", "--keymap", "us", *extra, disk]
sys.exit(m.main())
PY
}

ID=(--expect-size 1000204886016 --expect-serial S6B0NX0R123456A)

# the failed event's restored, and the partitions sfdisk was told to delete
restored() { echo "$output" | jq -r 'select(.stage? == "failed") | .restored'; }
deleted() { grep '^sfdisk --delete' "$T/calls" | sed "s|^sfdisk --delete $DISK ||" | tr '\n' ' '; }

@test "a failed erase never says the disk is as it was, even with every partition it made taken back" {
    FAIL_AT="cryptsetup open" run --separate-stderr system erase "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(deleted)" = "1 2 3 " ]
    [ "$(restored)" = "false" ]
}

@test "a failed alongside install that took back all it made is as it was" {
    FAIL_AT="cryptsetup open" run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(deleted)" = "2 3 " ]
    [ "$(restored)" = "true" ]
}

@test "a udev settle that times out after the disk step still takes back what was made" {
    FAIL_AT="udevadm settle" run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r 'select(.stage? == "failed") | .error')" = "udevadm exited 1: stopped by the test" ]
    # the partitions repart reported, gone; the ESP it shares, kept
    [ "$(deleted)" = "2 3 " ]
    [ "$(restored)" = "true" ]
    FAIL_AT="udevadm settle" run --separate-stderr system erase "${ID[@]}"
    [ "$(restored)" = "false" ]
}

@test "the disk tool failing while writing means the disk changed; refusing means it didn't" {
    # 3: repart failed partway. Which partitions exist is unknown: none are
    # deleted on a guess, and the disk is never called as it was
    DISK_EXIT=3 run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(restored)" = "false" ]
    [ "$(deleted)" = "" ]
    # killed, or crashed: the same
    DISK_EXIT=1 run --separate-stderr system alongside "${ID[@]}"
    [ "$(restored)" = "false" ]
    # 2: refused before writing anything. Even an erase is as it was
    DISK_EXIT=2 run --separate-stderr system erase "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(restored)" = "true" ]
    [ "$(deleted)" = "" ]
}

@test "the disk tool is told which drive was chosen, for the plan and the install; an install without it is refused" {
    run --separate-stderr system erase --plan-only "${ID[@]}"
    [ "$status" -eq 0 ]
    run --separate-stderr system erase "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/disk-args")" = "$(printf '%s\n' \
        "plan --mode erase --expect-size 1000204886016 --expect-serial S6B0NX0R123456A $DISK" \
        "apply --mode erase --key-file $T/key --expect-size 1000204886016 --expect-serial S6B0NX0R123456A $DISK")" ]
    rm "$T/disk-args"
    run --separate-stderr system erase --expect-size 1000204886016
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"installing needs --expect-size and --expect-serial"* ]]
    [ ! -e "$T/disk-args" ]
}

@test "a finished install keeps its log in the installed system's /var/log, written before it is unmounted" {
    run --separate-stderr system erase "${ID[@]}"
    [ "$status" -eq 0 ]
    local log
    log=$(find "$T/run" -path '*/ostree/deploy/default/var/log/pulsar-install.log')
    [ -n "$log" ]
    [ "$(stat -c %a "$log")" = 644 ]
    head -1 "$log" | grep -q '^--- pulsar-install-system, '
    # the whole run: how it was started, the disk step's log, the end
    grep -qF " \$ pulsar-install-system --mode erase --key-file $T/key " "$log"
    grep -qF ' {"log": "Encrypting future partition 3..."}' "$log"
    grep -qF ' stderr: + '"$T"'/disk-tool apply --mode erase' "$log"
    grep -qF ' {"stage": "done", "ok": true,' "$log"
    # every umount came after the log was written
    [ "$(grep -c '^cleanup umount' "$T/calls")" -eq 3 ]
    [ "$(grep -c '^cleanup umount .* (log kept)$' "$T/calls")" -eq 3 ]
}

# pulsar-install-disk's main(), with lsblk and systemd-repart answered here.
# LSBLK: the identity lsblk reports at each call, "size serial;..." in order.
# DRY_RC / REAL_RC: repart's exit status for the dry run and the real one.
tool() {
    PULSAR_INSTALLER_LAYOUTS="$LAYOUTS" python3 - "$TOOL" "$@" <<'PY'
import importlib.machinery as M, importlib.util as U, json, os, subprocess, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
answers = [a.split(" ", 1) for a in os.environ.get("LSBLK", "").split(";") if a]
seq = []
PLAN = [{"type": t, "activity": "create", "uuid": f"0000000{i}-0000-0000-0000-000000000000", "label": t}
        for i, t in enumerate(("esp", "xbootldr", "root-x86-64"))]

def fake(cmd, *a, **k):
    if cmd[0] == "lsblk":
        seq.append("lsblk")
        size, serial = answers.pop(0)
        return subprocess.CompletedProcess(cmd, 0, json.dumps({"blockdevices": [{"size": int(size), "serial": serial}]}), "")
    if cmd[0] == "systemd-repart":
        dry = "--dry-run=yes" in cmd
        seq.append("repart-dry" if dry else "repart-WRITE")
        rc = int(os.environ.get("DRY_RC" if dry else "REAL_RC", "0"))
        return subprocess.CompletedProcess(cmd, rc, json.dumps(PLAN) if rc == 0 else "", "Device busy")
    raise SystemExit(f"unexpected command {cmd}")

m.subprocess.run = fake
sys.argv = ["pulsar-install-disk", *sys.argv[2:]]
code = m.main()
print("SEQ", " ".join(seq))
sys.exit(code)
PY
}

@test "disk tool: the chosen drive is checked before planning and again just before writing" {
    LSBLK="1000204886016 S6B0NX0R123456A;1000204886016 S6B0NX0R123456A" \
        run --separate-stderr tool apply --mode erase --key-file "$T/key" "${ID[@]}" "$DISK"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "SEQ lsblk repart-dry lsblk repart-WRITE" ]
}

@test "disk tool: a different drive at the chosen name is refused, and never written" {
    # swapped while the plan was made: the first look matched, the second didn't
    LSBLK="1000204886016 S6B0NX0R123456A;256060514304 WD-WX12A3456789" \
        run --separate-stderr tool apply --mode erase --key-file "$T/key" "${ID[@]}" "$DISK"
    [ "$status" -eq 2 ]
    [ "$output" = "SEQ lsblk repart-dry lsblk" ]
    [ "$stderr" = "pulsar-install-disk: refused: $DISK is no longer the disk you chose: it was 1000204886016 bytes, serial ending 456A, and is now 256060514304 bytes, serial ending 6789. Was a disk unplugged or swapped?" ]
    # same size, another serial: refused before planning
    LSBLK="1000204886016 S6B0NX0R999999Z" run --separate-stderr tool plan --mode erase \
        --expect-size 1000204886016 --expect-serial S6B0NX0R123456A "$DISK"
    [ "$status" -eq 2 ]
    [ "$output" = "SEQ lsblk" ]
    # same serial, another size (a card reader's slot, a reformatted
    # namespace): refused
    LSBLK="500107862016 S6B0NX0R123456A" run --separate-stderr tool plan --mode erase \
        --expect-size 1000204886016 --expect-serial S6B0NX0R123456A "$DISK"
    [ "$status" -eq 2 ]
    [ "$stderr" = "pulsar-install-disk: refused: $DISK is no longer the disk you chose: it was 1000204886016 bytes, serial ending 456A, and is now 500107862016 bytes, serial ending 456A. Was a disk unplugged or swapped?" ]
    # a drive with no serial must still have none
    LSBLK="1000204886016 S6B0NX0R123456A" run --separate-stderr tool plan --mode erase \
        --expect-size 1000204886016 --expect-serial "" "$DISK"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"it was 1000204886016 bytes, no serial number, and is now"* ]]
}

@test "disk tool: refused before writing exits 2; failed while writing exits 3" {
    LSBLK="1000204886016 S6B0NX0R123456A" DRY_RC=1 \
        run --separate-stderr tool apply --mode erase --key-file "$T/key" "${ID[@]}" "$DISK"
    [ "$status" -eq 2 ]
    [ "$output" = "SEQ lsblk repart-dry" ]
    LSBLK="1000204886016 S6B0NX0R123456A;1000204886016 S6B0NX0R123456A" REAL_RC=1 \
        run --separate-stderr tool apply --mode erase --key-file "$T/key" "${ID[@]}" "$DISK"
    [ "$status" -eq 3 ]
    [ "$output" = "SEQ lsblk repart-dry lsblk repart-WRITE" ]
    [ "$stderr" = "pulsar-install-disk: failed while writing the disk: systemd-repart exited 1" ]
}
