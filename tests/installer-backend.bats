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
# drive's identity. FAIL_AT="<command prefix>[;<prefix>...]" makes those
# commands fail ("bootc" fails the stand-in bootc after it has written).
# ESP_SHIMS="ubuntu ...": other systems' shims already on the ESP, there once
# it is mounted; ESP_FALLBACK=TEXT: the ESP's EFI/BOOT/BOOTX64.EFI before the
# install. ESP_BOOT_STUCK=1: bootc leaves a directory where EFI/BOOT/BOOTX64.EFI
# goes, so the file can't be put back, by root either. ESP_WINDOWS=1: Windows'
# boot manager is on the ESP. APP_GONE_AFTER=N: the app goes away after N
# event lines, closing both pipes (each print after that fails as a closed
# pipe does). SIGNAL_AT_BOOTC=TERM|HUP: that signal arrives while bootc runs.
# A Fedora-family Linux beside: FEDORA_STUB=fedora|bootupd|bootupd-label puts
# its EFI/fedora on the ESP (Fedora's stub grub.cfg naming FEDORA_UUID;
# bootupd's static grub.cfg with bootuuid.cfg; or without it, by label);
# OTHER_BOOT=FSTYPE adds its /boot as partition 4 (filesystem UUID FEDORA_UUID,
# label "boot"), holding OTHER_GRUB=grub2|boot/grub2|none.
# stdout: the backend's events; $T/calls: every command run(), in order.
system() {
    local mode=$1; shift
    FIX="${BATS_TEST_DIRNAME}/fixtures/installer" PULSAR_INSTALL_DISK="$T/disk-tool" \
        python3 - "$SYS" "$T" "$DISK" "$mode" "$@" <<'PY'
import importlib.machinery as M, importlib.util as U, json, os, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
T, disk, mode, extra = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
ROOT, BOOT, ESPU = ("11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222",
                    "33333333-3333-3333-3333-333333333333")
m.os.geteuid = lambda: 0
m.SCRATCH = T + "/run"
if os.environ.get("APP_GONE_AFTER"):
    left = [int(os.environ["APP_GONE_AFTER"])]

    class Pipe:
        # a pipe whose reader has gone: every write fails, until its fd is
        # pointed somewhere else
        def __init__(self, real, counts):
            self.real, self.counts = real, counts
        def broken(self):
            return left[0] <= 0 and not os.path.samestat(os.fstat(self.real.fileno()), os.stat(os.devnull))
        def write(self, text):
            if self.broken():
                raise BrokenPipeError(32, "Broken pipe")
            if self.counts:
                left[0] -= text.count("\n")
            return self.real.write(text)
        def flush(self):
            if self.broken():
                raise BrokenPipeError(32, "Broken pipe")
            self.real.flush()
        def fileno(self):
            return self.real.fileno()
    sys.stdout, sys.stderr = Pipe(sys.stdout, True), Pipe(sys.stderr, False)
# booted via EFI, as the live system is: the firmware entry is made
m.EFIVARS = T
calls = open(T + "/calls", "a", buffering=1)
fail_at = [f for f in os.environ.get("FAIL_AT", "").split(";") if f]
parts = [("p1", 1, m.ESP_TYPE, ESPU, "vfat", "ESPFS"), ("p2", 2, "bc13c2ff-59e6-4262-a352-b275fd6f7172", BOOT, "ext4", "BOOTFS"),
         ("p3", 3, "4f68bce3-e8cd-4db1-96e7-fbcaf984b709", ROOT, "crypto_LUKS", "LUKSUUID")]
FEDORA_UUID = os.environ.get("FEDORA_UUID", "")
if os.environ.get("OTHER_BOOT"):
    parts.append(("p4", 4, "0fc63daf-8483-4772-8e79-3d69d8477de4", "55555555-5555-5555-5555-555555555555",
                  os.environ["OTHER_BOOT"], FEDORA_UUID))
STUBS = {
    # Fedora's own (grub2-efi, as Anaconda writes it)
    "fedora": ({"grub.cfg": f"search --no-floppy --root-dev-only --fs-uuid --set=dev {FEDORA_UUID}\n"
                            "set prefix=($dev)/grub2\n\nexport $prefix\nconfigfile $prefix/grub.cfg\n"}),
    # bootupd's static one (Fedora Atomic, bootc), and its bootuuid.cfg
    "bootupd": {"grub.cfg": open(os.path.join(os.environ["FIX"], "bootupd-grub-static-efi.cfg")).read(),
                "bootuuid.cfg": f'set BOOT_UUID="{FEDORA_UUID}"\n'},
}
STUBS["bootupd-label"] = {"grub.cfg": STUBS["bootupd"]["grub.cfg"]}
state = {"target": None}
real_run, real_subprocess_run, real_popen = m.run, m.subprocess.run, m.subprocess.Popen

def run(*cmd, **kw):
    line = " ".join(cmd)
    calls.write(line + "\n")
    if any(line.startswith(f) for f in fail_at):
        raise m.Failed(f"{cmd[0]} exited 1: stopped by the test", 1)
    if cmd[0] == m.DISK_TOOL:
        return real_run(*cmd, **kw)
    if cmd[0] == "lsblk":
        return json.dumps({"blockdevices": [{"path": disk, "children": [
            {"path": disk + n, "pkname": disk, "partn": k, "parttype": t, "partuuid": u, "fstype": f, "uuid": fu,
             "label": "boot" if n == "p4" else None}
            for n, k, t, u, f, fu in parts]}]})
    if cmd[0] == "sfdisk" and cmd[1] == "-J":
        return json.dumps({"partitiontable": {"partitions": [{"node": disk + n, "uuid": u} for n, _, _, u, _, _ in parts]}})
    if cmd[0] == "mount" and os.environ.get("ESP_WINDOWS") and cmd[-1].endswith(("/boot/efi", "/esp-check")):
        os.makedirs(os.path.join(cmd[-1], "EFI/Microsoft/Boot"), exist_ok=True)
        open(os.path.join(cmd[-1], "EFI/Microsoft/Boot/bootmgfw.efi"), "w").close()
    if cmd[0] == "mount" and cmd[-1].endswith(("/boot/efi", "/esp-check")):
        for v in os.environ.get("ESP_SHIMS", "").split():
            os.makedirs(os.path.join(cmd[-1], "EFI", v), exist_ok=True)
            open(os.path.join(cmd[-1], "EFI", v, "shimx64.efi"), "w").close()
        for name, text in STUBS.get(os.environ.get("FEDORA_STUB"), {}).items():
            os.makedirs(os.path.join(cmd[-1], "EFI/fedora"), exist_ok=True)
            open(os.path.join(cmd[-1], "EFI/fedora", name), "w").write(text)
    if cmd[0] == "mount" and cmd[-1].endswith("/linux-boot-check") and os.environ.get("OTHER_GRUB", "none") != "none":
        g, top = os.environ["OTHER_GRUB"], cmd[-1]
        os.makedirs(os.path.join(top, g), exist_ok=True)
        open(os.path.join(top, g, "grub.cfg"), "w").write("blscfg\n")
        entries = os.path.join(top, os.path.dirname(g), "loader/entries")
        os.makedirs(entries, exist_ok=True)
        open(os.path.join(entries, "abc-6.17.1-200.fc42.x86_64.conf"), "w").write(
            "title Fedora Linux (6.17.1-200.fc42.x86_64) 42 (Workstation Edition)\nversion 6.17.1-200.fc42.x86_64\n")
    if cmd[0] == "mount" and cmd[-1].endswith("/boot/efi"):
        if os.environ.get("ESP_FALLBACK"):
            os.makedirs(os.path.join(cmd[-1], "EFI/BOOT"), exist_ok=True)
            open(os.path.join(cmd[-1], "EFI/BOOT/BOOTX64.EFI"), "w").write(os.environ["ESP_FALLBACK"])
    if cmd[0] in ("udevadm", "cryptsetup", "mount", "umount", "efibootmgr", "sfdisk"):
        return ""
    raise SystemExit(f"unexpected command {cmd}")

def run_stream(*cmd, **kw):
    # bootc: a deployment with the image's EFI payload, its stateroot's /var,
    # and that payload's shim copied to the ESP, as bootupd does: into
    # EFI/fedora and over EFI/BOOT
    target = cmd[-1]
    calls.write("bootc install to-filesystem " + target + "\n")
    state["target"] = target
    payload = "ostree/deploy/default/deploy/abc.0/usr/lib/efi/shim/16.1-7/EFI/fedora"
    for d in ("ostree/deploy/default/deploy/abc.0/etc", "ostree/deploy/default/var/log", "boot/efi/EFI/fedora",
              "boot/efi/EFI/BOOT", "boot/grub2", payload):
        os.makedirs(os.path.join(target, d), exist_ok=True)
    for f in (payload + "/shimx64.efi", "boot/efi/EFI/fedora/shimx64.efi"):
        open(os.path.join(target, f), "w").close()
    for f in ("BOOTX64.EFI", "fbx64.efi"):
        if os.environ.get("ESP_BOOT_STUCK") and f == "BOOTX64.EFI":
            stuck = os.path.join(target, "boot/efi/EFI/BOOT", f)
            if os.path.isfile(stuck):
                os.unlink(stuck)
            os.makedirs(stuck, exist_ok=True)
            continue
        open(os.path.join(target, "boot/efi/EFI/BOOT", f), "w").write("PULSAR-SHIM")
    if os.environ.get("SIGNAL_AT_BOOTC"):
        import signal
        os.kill(os.getpid(), getattr(signal, "SIG" + os.environ["SIGNAL_AT_BOOTC"]))
    if "bootc" in fail_at:
        raise m.Failed("bootc exited 1: stopped by the test", 1)

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

# the failed event's restored, its disk and esp, and the partitions sfdisk
# was told to delete
restored() { echo "$output" | jq -r 'select(.stage? == "failed") | .restored'; }
known() { echo "$output" | jq -r 'select(.stage? == "failed") | "\(.disk) \(.esp)"'; }
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

@test "the failed event says what is known: nothing written, unknown, or Pulsar's partitions removed or left" {
    # refused: nothing written, either way
    DISK_EXIT=2 run --separate-stderr system alongside "${ID[@]}"
    [ "$(known)" = "unchanged unchanged" ]
    DISK_EXIT=2 run --separate-stderr system erase "${ID[@]}"
    [ "$(known)" = "unchanged null" ]
    # failed while writing (3), or crashed (1): what is on the disk is unknown
    DISK_EXIT=3 run --separate-stderr system erase "${ID[@]}"
    [ "$(known)" = "unknown null" ]
    [ "$(restored)" = "false" ]
    DISK_EXIT=1 run --separate-stderr system erase "${ID[@]}"
    [ "$(known)" = "unknown null" ]
    DISK_EXIT=3 run --separate-stderr system alongside "${ID[@]}"
    [ "$(known)" = "unknown unchanged" ]
    # partitioned, then failed before bootc: what it made is taken back
    FAIL_AT="cryptsetup open" run --separate-stderr system erase "${ID[@]}"
    [ "$(known)" = "removed null" ]
    FAIL_AT="cryptsetup open" run --separate-stderr system alongside "${ID[@]}"
    [ "$(known)" = "removed unchanged" ]
}

@test "partitions that can't be taken back are reported left, and the disk is never called as it was" {
    FAIL_AT="cryptsetup open;sfdisk --delete" run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(known)" = "left unchanged" ]
    [ "$(restored)" = "false" ]
    FAIL_AT="cryptsetup open;sfdisk --delete" run --separate-stderr system erase "${ID[@]}"
    [ "$(known)" = "left null" ]
    [ "$(restored)" = "false" ]
}

@test "a failed install beside Windows puts Windows' EFI/BOOT back, and says so" {
    ESP_FALLBACK=WINDOWS-BOOTMGR FAIL_AT=bootc run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 1 ]
    [ "$(known)" = "removed boot_files" ]
    local boot
    boot=$(find "$T/run" -path '*/boot/efi/EFI/BOOT' -type d)
    [ "$(ls "$boot")" = BOOTX64.EFI ]
    [ "$(cat "$boot/BOOTX64.EFI")" = WINDOWS-BOOTMGR ]
    # put back before the ESP is unmounted, and before the partitions go
    [ "$(grep -n 'put EFI/BOOT on the ESP back' <<<"$stderr" | cut -d: -f1)" -lt \
      "$(grep -n 'removed the 2 partitions' <<<"$stderr" | cut -d: -f1)" ]
    # it can't be put back: the event says EFI/BOOT may be Pulsar's
    rm -rf "$T/run"
    ESP_FALLBACK=WINDOWS-BOOTMGR ESP_BOOT_STUCK=1 FAIL_AT=bootc run --separate-stderr system alongside "${ID[@]}"
    [ "$(known)" = "removed fallback" ]
}

@test "the plan says whether Windows' boot manager is on the ESP it shares, the test the menu entry uses" {
    ESP_WINDOWS=1 run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r 'select(.stage? == "plan") | .windows')" = true ]
    grep -q '^mount -o ro .*/esp-check$' "$T/calls"
    run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$(echo "$output" | jq -r 'select(.stage? == "plan") | .windows')" = false ]
    # an erase shares no ESP
    run --separate-stderr system erase --plan-only "${ID[@]}"
    [ "$(echo "$output" | jq -r 'select(.stage? == "plan") | .windows')" = null ]
    # and the install itself makes the entry on the same test
    ESP_WINDOWS=1 run --separate-stderr system alongside "${ID[@]}"
    [ "$(echo "$output" | jq -r 'select(.stage? == "done") | .windows_entry')" = true ]
}

@test "the install carries on when the app goes away mid-install, and nothing is cleaned up under it" {
    # the app reads check and disk, and is gone as the disk tool's first line comes
    APP_GONE_AFTER=3 run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .stage)" = "$(printf '%s\n' check disk)" ]
    ! grep -q '^sfdisk --delete' "$T/calls"
    grep -q '^bootc install to-filesystem ' "$T/calls"
    # the kept log has the rest, which the app never saw
    local log
    log=$(find "$T/run" -path '*/ostree/deploy/default/var/log/pulsar-install.log')
    grep -qF ' {"stage": "done", "ok": true,' "$log"
}

@test "SIGTERM or SIGHUP stops the install in order: the failed event, Pulsar's partitions taken back, EFI/BOOT put back" {
    for sig in TERM HUP; do
        rm -f "$T/calls"; rm -rf "$T/run"
        ESP_FALLBACK=WINDOWS-BOOTMGR SIGNAL_AT_BOOTC=$sig run --separate-stderr system alongside "${ID[@]}"
        [ "$status" -eq 1 ]
        [ "$(echo "$output" | jq -r 'select(.stage? == "failed") | .error')" = "stopped by SIG$sig" ]
        [ "$(known)" = "removed boot_files" ]
        [ "$(deleted)" = "2 3 " ]
    done
}

@test "a step cut short by a signal ends its command and waits for it before the clean-up" {
    run python3 - "$SYS" "$T/wrote" <<'PY'
import importlib.machinery as M, importlib.util as U, os, sys, time
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
m.stop_on_signals()
# a command that is told to stop while it works (the signal comes to the
# backend, as the session's end would send it), then writes, a second later
try:
    m.run_stream("sh", "-c", 'echo working; kill -TERM $PPID; sleep 1; echo done > "$0"', sys.argv[2])
    print("not stopped")
except m.Stopped as e:
    print(e)
time.sleep(2)
print("wrote after the stop:", os.path.exists(sys.argv[2]))
PY
    [ "${lines[${#lines[@]}-2]}" = "stopped by SIGTERM" ]
    [ "${lines[${#lines[@]}-1]}" = "wrote after the stop: False" ]
}

@test "a signal that lands while a command is being started still ends that command before the clean-up" {
    # the signal arrives as Popen() returns, before run_stream (or run_logged)
    # holds the process: it used to be raised inside Popen(), leaving the
    # command running
    for step in run_stream run_logged; do
        rm -f "$T/wrote"
        run --separate-stderr python3 - "$SYS" "$T/wrote" "$step" <<'PY'
import importlib.machinery as M, importlib.util as U, os, signal, sys, time
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
m.stop_on_signals()
real = m.subprocess.Popen

def popen(*a, **k):
    p = real(*a, **k)
    os.kill(os.getpid(), signal.SIGTERM)
    return p
m.subprocess.Popen = popen
try:
    getattr(m, sys.argv[3])("sh", "-c", 'sleep 1; echo done > "$0"', sys.argv[2])
    print("not stopped")
except m.Stopped as e:
    print(e)
time.sleep(2)
print("wrote after the stop:", os.path.exists(sys.argv[2]))
PY
        [ "$output" = "$(printf '%s\n' 'stopped by SIGTERM' 'wrote after the stop: False')" ]
    done
}

FED=8c3e7a52-1d4f-4a6b-9e0c-2f5b7d9a1c34
custom_cfg() { local f; f=$(find "$T/run" -path '*/target/boot/grub2/custom.cfg' 2>/dev/null); [ -z "$f" ] || cat "$f"; }
plan_field() { echo "$output" | jq -c "select(.stage? == \"plan\") | .$1"; }
done_field() { echo "$output" | jq -c "select(.stage? == \"done\") | .$1"; }

@test "beside a Fedora-family Linux, the startup menu gets an entry that starts it through its own GRUB configuration" {
    # Fedora Workstation: Anaconda's stub in EFI/fedora, an ext4 /boot with grub2/grub.cfg
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=grub2 run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(plan_field fedora_linux)" = '{"menu":true,"title":"Fedora Linux 42 (Workstation Edition)","uuid":"'$FED'","fs":"ext4","grub_mod":"ext2","grub_dir":"grub2"}' ]
    [ "$(plan_field other_loaders)" = '[]' ]
    # its /boot was mounted read-only, without replaying its journal
    grep -q "^mount -t ext4 -o ro,noload ${DISK}p4 .*/linux-boot-check$" "$T/calls"
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=grub2 run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(done_field linux_entry)" = '"Fedora Linux 42 (Workstation Edition)"' ]
    local want="
menuentry 'Fedora Linux 42 (Workstation Edition)' --class fedora --class gnu-linux --class os {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=dev $FED
	set prefix=(\$dev)/grub2
	export prefix
	configfile \$prefix/grub.cfg
}

# Another system is installed beside Pulsar: time to choose it
if [ \"\${timeout}\" = \"1\" ]; then
	set timeout=5
fi"
    [ "$(custom_cfg)" = "$want" ]
}

@test "a Fedora Atomic or bootc Linux (bootupd's EFI/fedora) is found by its bootuuid.cfg, or by the label boot without one" {
    rm -rf "$T/run"
    FEDORA_STUB=bootupd FEDORA_UUID=$FED OTHER_BOOT=btrfs OTHER_GRUB=boot/grub2 run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    grep -q "^mount -t btrfs -o ro,rescue=nologreplay ${DISK}p4 " "$T/calls"
    [[ "$(custom_cfg)" == *"	insmod btrfs
	search --no-floppy --fs-uuid --set=dev $FED
	set prefix=(\$dev)/boot/grub2
"* ]]
    rm -rf "$T/run"
    FEDORA_STUB=bootupd-label FEDORA_UUID=$FED OTHER_BOOT=xfs OTHER_GRUB=grub2 run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$(plan_field fedora_linux.uuid)" = "\"$FED\"" ]
    [ "$(plan_field fedora_linux.grub_mod)" = '"xfs"' ]
    grep -q "^mount -t xfs -o ro,norecovery ${DISK}p4 " "$T/calls"
}

@test "a Fedora-family Linux whose /boot or grub.cfg can't be found gets no entry, and the plan says so" {
    # /boot found, but no grub2 configuration on it
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=none run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(plan_field fedora_linux)" = "{\"menu\":false,\"why\":\"no grub2/grub.cfg on ${DISK}p4\"}" ]
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=none run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(done_field linux_entry)" = null ]
    [ "$(done_field fedora_linux.menu)" = false ]
    [[ "$(custom_cfg)" != *menuentry* ]]
    # the stub names a /boot that isn't on this disk
    FEDORA_STUB=fedora FEDORA_UUID=$FED run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$(plan_field fedora_linux)" = "{\"menu\":false,\"why\":\"0 partitions on $DISK have the uuid $FED\"}" ]
    # a /boot GRUB can't read
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=crypto_LUKS run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$(plan_field fedora_linux)" = '{"menu":false,"why":"its /boot is crypto_LUKS"}' ]
}

@test "beside Ubuntu (its own shim and GRUB), no startup menu entry; the plan and the done event name its loader" {
    ESP_SHIMS=ubuntu run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$(plan_field other_loaders)" = '["ubuntu"]' ]
    [ "$(plan_field fedora_linux)" = null ]
    ESP_SHIMS=ubuntu run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(done_field other_loaders)" = '["ubuntu"]' ]
    [ "$(done_field linux_entry)" = null ]
    [[ "$(custom_cfg)" != *menuentry* ]]
    # an erase shares no ESP: nothing to report
    run --separate-stderr system erase --plan-only "${ID[@]}"
    [ "$(plan_field 'fedora_linux, .other_loaders')" = "$(printf 'null\n[]')" ]
}

# grub_cfg: /boot/grub2/grub.cfg as bootupd assembles its static config
# (grub-static-pre.cfg, then configs.d in name order), with the install's
# custom.cfg spliced in where 41_custom.cfg sources it
grub_cfg() {
    local static="${BATS_TEST_DIRNAME}/fixtures/installer/bootupd-grub2-static" f
    cat "$static/grub-static-pre.cfg"
    for f in "$static"/configs.d/*.cfg; do
        if grep -qF 'source $prefix/custom.cfg' "$f"; then custom_cfg; else cat "$f"; fi
    done
}
# the timeout GRUB ends up with, reading the assembled config top to bottom
# for its plain `set timeout=N` lines (the menu_show_once one is skipped:
# its variable isn't set)
grub_timeout() { grub_cfg | sed -n 's/^[[:space:]]*set timeout=\([0-9]\+\)$/\1/p' | tail -1; }

@test "with another system beside Pulsar the startup menu shows for 5 seconds; Pulsar alone or an erase keeps bootupd's 1" {
    local static="${BATS_TEST_DIRNAME}/fixtures/installer/bootupd-grub2-static" raw
    # bootupd's own order: timeout=1 is set before custom.cfg is sourced
    raw=$(cat "$static/grub-static-pre.cfg" "$static"/configs.d/*.cfg)
    [ "$(grep -n 'set timeout=1$' <<<"$raw" | cut -d: -f1)" -lt "$(grep -n 'source \$prefix/custom.cfg' <<<"$raw" | cut -d: -f1)" ]
    five() {
        [ "$status" -eq 0 ]
        [ "$(done_field menu_timeout)" = 5 ]
        [[ "$(custom_cfg)" == *'if [ "${timeout}" = "1" ]; then
	set timeout=5
fi'* ]]
        [ "$(grub_timeout)" = 5 ]
    }
    ESP_WINDOWS=1 run --separate-stderr system alongside "${ID[@]}"
    five
    rm -rf "$T/run"
    ESP_SHIMS=ubuntu run --separate-stderr system alongside "${ID[@]}"
    five
    rm -rf "$T/run"
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=grub2 run --separate-stderr system alongside "${ID[@]}"
    five
    # Pulsar alone beside data: no change
    rm -rf "$T/run"
    run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(done_field menu_timeout)" = null ]
    [ "$(grub_timeout)" = 1 ]
    # an erase: never
    rm -rf "$T/run"
    ESP_WINDOWS=1 run --separate-stderr system erase "${ID[@]}"
    [ "$status" -eq 0 ]
    [ "$(done_field menu_timeout)" = null ]
    [ "$(grub_timeout)" = 1 ]
}

# notes_say STAGE: the app's startup notes from the backend's STAGE event in $output
notes_say() {
    python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-installer" "$1" "$output" <<'PY'
import importlib.machinery as M, importlib.util as U, json, sys
l = M.SourceFileLoader("a", sys.argv[1]); a = U.module_from_spec(U.spec_from_loader("a", l)); l.exec_module(a)
ev = next(e for e in map(json.loads, sys.argv[3].splitlines()) if e.get("stage") == sys.argv[2])
print("\n".join(a.startup_notes(ev)))
PY
}

@test "the app's pages say what the backend found and made: a menu entry, no entry, or the computer's boot menu" {
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=grub2 run --separate-stderr system alongside --plan-only "${ID[@]}"
    [ "$(notes_say plan)" = "To start Fedora Linux 42 (Workstation Edition), choose it in the startup menu." ]
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=grub2 run --separate-stderr system alongside "${ID[@]}"
    [ "$(notes_say done)" = "To start Fedora Linux 42 (Workstation Edition), choose it in the startup menu." ]
    FEDORA_STUB=fedora FEDORA_UUID=$FED OTHER_BOOT=ext4 OTHER_GRUB=none run --separate-stderr system alongside "${ID[@]}"
    [[ "$(notes_say done)" == "The installer couldn't find the other Linux's boot configuration, so it won't be in the startup menu."* ]]
    ESP_SHIMS=ubuntu ESP_WINDOWS=1 run --separate-stderr system alongside "${ID[@]}"
    [ "$(notes_say done)" = "$(printf '%s\n' "To start Windows, choose it in the startup menu." \
        "To start Ubuntu, choose it in the computer's own boot menu. The key that opens it depends on the computer's maker.")" ]
}

# page_says MODE: the failure page's sentence about the disk, as the installer
# app words it from the events in $output
page_says() {
    python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-installer" "$1" "$output" <<'PY'
import importlib.machinery as M, importlib.util as U, json, sys
l = M.SourceFileLoader("a", sys.argv[1]); a = U.module_from_spec(U.spec_from_loader("a", l)); l.exec_module(a)
events = [json.loads(line) for line in sys.argv[3].splitlines() if line.strip()]
print(a.failure_state(sys.argv[2], a.disk_state(events)))
PY
}

@test "the failure page says what the backend knows: nothing changed, unknown, erased, or what is left" {
    DISK_EXIT=2 run --separate-stderr system alongside "${ID[@]}"
    [ "$(page_says alongside)" = "Nothing on the disk was changed." ]
    DISK_EXIT=2 run --separate-stderr system erase "${ID[@]}"
    [ "$(page_says erase)" = "Nothing on the disk was changed." ]
    for code in 1 3; do
        DISK_EXIT=$code run --separate-stderr system erase "${ID[@]}"
        [ "$(page_says erase)" = "The disk may have been erased. What is on it now is unknown." ]
    done
    FAIL_AT="cryptsetup open;sfdisk --delete" run --separate-stderr system erase "${ID[@]}"
    [ "$(page_says erase)" = "The disk was erased, and Pulsar's new partitions may still be on it." ]
    FAIL_AT="cryptsetup open;sfdisk --delete" run --separate-stderr system alongside "${ID[@]}"
    [ "$(page_says alongside)" = "Pulsar's new partitions may still be on the disk. The disk's other partitions weren't changed." ]
    ESP_FALLBACK=WINDOWS-BOOTMGR FAIL_AT=bootc run --separate-stderr system alongside "${ID[@]}"
    [ "$(page_says alongside)" = "Pulsar's new partitions were removed. The startup files (EFI) partition may still have Pulsar's boot files in it. The other partitions weren't changed." ]
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

@test "beside a Linux with its own shim (Ubuntu, Debian), the firmware entry starts Pulsar's shim, the image's own" {
    ESP_SHIMS="ubuntu debian" run --separate-stderr system alongside "${ID[@]}"
    [ "$status" -eq 0 ]
    grep -qFx "efibootmgr --create --disk $DISK --part 1 --loader \\EFI\\fedora\\shimx64.efi --label Pulsar" "$T/calls"
    [ "$(echo "$output" | jq -r 'select(.stage? == "done") | .firmware')" = 'firmware entry Pulsar -> \EFI\fedora\shimx64.efi' ]
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
