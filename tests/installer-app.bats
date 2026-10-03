#!/usr/bin/env bats
# The installer app's disk logic: which disks are offered, what each holds,
# its free space, and which ways of installing it allows, over disks shaped
# like real ones (tests/fixtures/installer/disks.json; nvme0n1 is lsblk's
# own output on a Pulsar machine). No GTK needed: the logic is plain Python.

setup() {
    APP="${BATS_TEST_DIRNAME}/../scripts/pulsar-installer"
    FIX="${BATS_TEST_DIRNAME}/fixtures/installer/disks.json"
}

# py EXPR: evaluate EXPR with the app's module as m and the fixture's disks as D
py() {
    python3 - "$APP" "$FIX" "$1" <<'PY'
import importlib.machinery as M, importlib.util as U, json, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
D = {d["path"]: d for d in m.disks(json.load(open(sys.argv[2])))}
print(eval(sys.argv[3]))
PY
}

@test "offered: real disks only; not zram, the CD, or the installer's own stick" {
    run py 'sorted(D)'
    [ "$status" -eq 0 ]
    [ "$output" = "['/dev/nvme0n1', '/dev/nvme1n1', '/dev/sda', '/dev/sdb', '/dev/sdc', '/dev/sde', '/dev/vda']" ]
}

@test "names read like the drive: NVMe underscores become spaces, SATA keeps its vendor" {
    [ "$(py 'D["/dev/nvme0n1"]["name"]')" = "SKHynix HFS001TEJ9X115N" ]
    [ "$(py 'D["/dev/sda"]["name"]')" = "ATA Crucial MX500" ]
}

@test "what each disk holds" {
    run py '[D[k]["holds"] for k in ("/dev/nvme0n1", "/dev/nvme1n1", "/dev/sda", "/dev/sdb", "/dev/sde")]'
    [ "$output" = "['Linux', 'Windows', 'Windows', 'nothing', 'other data']" ]
    [ "$(py 'D["/dev/sda"]["bitlocker"]')" = "True" ]
}

@test "free space: the gap between Windows and its recovery partition, not the disk's size" {
    # C: ends at 239616*512 + 500 GiB; recovery starts at sector 1952000000
    run py 'round(D["/dev/nvme1n1"]["free"] / 2**30, 1)'
    [ "$output" = "430.7" ]
    run py 'D["/dev/nvme0n1"]["free"] < 2**30'
    [ "$output" = "True" ]
}

@test "Windows with room beside it: both ways offered, alongside says Windows stays" {
    run py 'm.options(D["/dev/nvme1n1"])'
    [[ "$output" == *"'alongside': (True, 'Uses the 462 GB of free space. Windows stays as it is.')"* ]]
    [[ "$output" == *"'erase': (True,"* ]]
}

@test "BitLocker: alongside refused, with what to do about it" {
    run py 'm.options(D["/dev/sda"])["alongside"]'
    [[ "$output" == "(False, 'BitLocker is on."* ]]
}

@test "a full disk: alongside refused with the numbers; an empty one: nothing to keep" {
    run py 'm.options(D["/dev/nvme0n1"])["alongside"][0]'
    [ "$output" = "False" ]
    run py 'm.options(D["/dev/sdb"])["alongside"]'
    [ "$output" = "(False, 'There is nothing on this disk to keep')" ]
    run py 'm.options(D["/dev/sdb"])["erase"][0]'
    [ "$output" = "True" ]
}

@test "a data disk with no EFI system partition can't be shared, only erased" {
    run py 'm.options(D["/dev/sde"])["alongside"][0], m.options(D["/dev/sde"])["erase"][0]'
    [ "$output" = "(False, True)" ]
}

@test "too small: neither way" {
    run py '[v[0] for v in m.options(D["/dev/sdc"]).values()]'
    [ "$output" = "[False, False]" ]
}

@test "passphrase: 8 characters and typed the same twice" {
    [ "$(py 'm.passphrase_problem("short", "short")')" = "Use at least 8 characters" ]
    [ "$(py 'm.passphrase_problem("correct horse", "correct hors")')" = "The passphrases don't match" ]
    [ "$(py 'm.passphrase_problem("correct horse", "correct horse")')" = "None" ]
}

@test "an NTFS data disk with no startup files is data, not a Windows install" {
    [ "$(py 'D["/dev/sde"]["windows"]')" = "False" ]
}

@test "the erase page names partitions in words" {
    run py '[p["what"] for p in D["/dev/nvme1n1"]["partitions"]]'
    [ "$output" = "['Startup files (EFI)', 'Microsoft reserved', 'Windows', 'Windows recovery']" ]
}

@test "a raw hex vendor (a VM's virtio disk: 0x1af4) is never a disk's name" {
    [ "$(py 'D["/dev/vda"]["name"]')" = "Virtual disk" ]
}

@test "an empty disk is offered one way: install on it, with no erase to confirm" {
    run py 'm.options(D["/dev/sdb"])["erase"]'
    [ "$output" = "(True, 'The disk is empty.')" ]
    [ "$(py 'm.method_title(D["/dev/sdb"], "erase")')" = "Install Pulsar on this disk" ]
    [ "$(py 'm.needs_erase_confirm(D["/dev/sdb"])')" = "False" ]
    [ "$(py 'm.needs_erase_confirm(D["/dev/nvme1n1"])')" = "True" ]
}

@test "the passphrase hint waits for the second entry before saying they differ" {
    [ "$(py 'm.passphrase_hint("correct horse", "")')" = "" ]
    [ "$(py 'm.passphrase_hint("short", "")')" = "Use at least 8 characters" ]
    [ "$(py 'm.passphrase_hint("correct horse", "correct")')" = "The passphrases don't match" ]
}

@test "the copy's progress fills the bar between its start and the boot setup" {
    [ "$(py 'round(m.install_fraction(0), 2), round(m.install_fraction(0.5), 2), round(m.install_fraction(1), 2), round(m.install_fraction(7), 2)')" = "(0.12, 0.53, 0.94, 0.94)" ]
}

@test "keyboard: GNOME's layout maps to the console keymap the boot prompt uses" {
    # systemd's table and the XKB registry as fixtures: a build host has neither
    local map="${BATS_TEST_DIRNAME}/fixtures/installer/kbd-model-map" xml="${BATS_TEST_DIRNAME}/fixtures/installer/evdev.xml"
    [ "$(py 'm.current_layout([("xkb", "de+nodeadkeys"), ("xkb", "us")])')" = "('de', 'nodeadkeys')" ]
    [ "$(py 'm.current_layout([])')" = "('us', '')" ]
    [ "$(py "m.console_keymap('de', mapfile='$map')")" = "de" ]
    [ "$(py "m.console_keymap('de', 'nodeadkeys', mapfile='$map')")" = "de-latin1-nodeadkeys" ]
    [ "$(py "m.console_keymap('gb', mapfile='$map')")" = "uk" ]
    [ "$(py "m.console_keymap('xx-nowhere', mapfile='$map')")" = "xx-nowhere" ]
    [ "$(py "m.layout_name('de', rules='$xml')")" = "German" ]
    [ "$(py "m.layout_name('de', 'nodeadkeys', rules='$xml')")" = "German (no dead keys)" ]
}

@test "Install is red only when it deletes something" {
    [ "$(py 'm.install_destroys("erase", D["/dev/sdb"])')" = "False" ]
    [ "$(py 'm.install_destroys("erase", D["/dev/nvme1n1"])')" = "True" ]
    [ "$(py 'm.install_destroys("alongside", D["/dev/nvme1n1"])')" = "False" ]
}

@test "the last button says it erases whenever it deletes something" {
    [ "$(py 'm.install_button("erase", D["/dev/nvme1n1"])')" = "Erase and Install" ]
    [ "$(py 'm.install_button("erase", D["/dev/sdb"])')" = "Install" ]
    [ "$(py 'm.install_button("alongside", D["/dev/nvme1n1"])')" = "Install" ]
}

@test "an empty disk skips the page asking how: erasing nothing is the one way" {
    [ "$(py 'm.skips_method(D["/dev/sdb"])')" = "True" ]
    [ "$(py 'm.skips_method(D["/dev/nvme1n1"])')" = "False" ]
}

@test "each disk is described by size, what is on it, and USB" {
    [ "$(py 'm.identity(D["/dev/nvme1n1"])')" = "1.0 TB · Windows" ]
    [ "$(py 'm.identity(D["/dev/sdb"])')" = "256 GB · Empty" ]
    # a data disk is named by its partitions' names
    [ "$(py 'm.identity(D["/dev/sde"])')" = "2.0 TB · Files (Games)" ]
}

@test "two drives of the same model never read the same" {
    run py '[d["name"] for d in m.tell_apart([
        {"name": "Samsung SSD", "serial": "S6B0NX0R123456A", "path": "/dev/nvme0n1"},
        {"name": "Samsung SSD", "serial": "", "path": "/dev/nvme1n1"},
        {"name": "Crucial MX500", "serial": "2203E5F1", "path": "/dev/sda"}])]'
    [ "$output" = "['Samsung SSD (serial ending 456A)', 'Samsung SSD (/dev/nvme1n1)', 'Crucial MX500']" ]
    # lsblk is asked for the serial
    [[ "$(py 'm.LSBLK_COLS')" == *",SERIAL,"* ]]
}

@test "after a failure the page says what state the disk is in, by mode" {
    [ "$(py 'm.failure_state("erase", True, planning=True)')" = "Nothing on the disk was changed." ]
    [ "$(py 'm.failure_state("erase", True)')" = "The disk is as it was before you pressed Install." ]
    [[ "$(py 'm.failure_state("alongside", False)')" == *"Everything that was on the disk before is untouched."* ]]
    [ "$(py 'm.failure_state("erase", False)')" = "The disk was erased, but Pulsar is not fully on it." ]
}

@test "elapsed time reads as minutes and seconds" {
    [ "$(py 'm.elapsed(0)')" = "Time so far: 0:00" ]
    [ "$(py 'm.elapsed(754)')" = "Time so far: 12:34" ]
}

@test "encryption off: every page says so, and the backend is told --no-encrypt" {
    [ "$(py 'm.passphrase_heading(False)[0]')" = "Install without encryption" ]
    [ "$(py 'm.passphrase_heading(False)[1]')" = "Anyone who has this computer or its disk can read the files on it." ]
    [ "$(py 'm.encryption_summary(False)')" = "Off. Anyone who has this computer or its disk can read the files on it." ]
    [ "$(py 'm.stages(False)["disk"][0]')" = "Partitioning the disk" ]
    [ "$(py '"unlock" in m.stages(False)')" = "False" ]
    [ "$(py 'm.first_start(False)')" = "When Pulsar starts, create your account." ]
    [ "$(py 'm.secret_args(None)')" = "['--no-encrypt']" ]
}

@test "encryption on: the passphrase, the unlock stage and the unlock prompt" {
    [ "$(py 'm.passphrase_heading(True)[0]')" = "Choose a passphrase" ]
    [ "$(py 'm.encryption_summary(True)')" = "On. Your passphrase unlocks the disk at every start." ]
    [ "$(py 'm.stages(True)["disk"][0]')" = "Partitioning and encrypting the disk" ]
    [ "$(py 'm.stages(True)["unlock"][0]')" = "Unlocking the new partition" ]
    [[ "$(py 'm.first_start(True)')" == *"type your passphrase to unlock the disk"* ]]
    [ "$(py 'm.secret_args("/run/user/1000/k")')" = "['--key-file', '/run/user/1000/k']" ]
}

@test "the bar moves forward through the stages either way" {
    for e in True False; do
        run py "[f for _, f in m.stages($e).values()] == sorted(f for _, f in m.stages($e).values())"
        [ "$output" = "True" ]
    done
}

@test "encryption copy: no exclamation marks, American spelling" {
    run py 'm.passphrase_heading(True) + m.passphrase_heading(False) + (m.encryption_summary(True), m.encryption_summary(False), m.first_start(True), m.first_start(False))'
    [[ "$output" != *"!"* ]]
    [[ "$output" != *"isation"* ]]
}

@test "the encryption switch starts on, and the app starts encrypted" {
    grep -q 'Adw.SwitchRow(title="Encrypt the disk", subtitle="Recommended", active=True)' "$APP"
    grep -q 'self.encrypt = True' "$APP"
}

@test "the fake backend skips the unlock stage when told --no-encrypt" {
    local fake="${BATS_TEST_DIRNAME}/fixtures/installer/fake-backend"
    run timeout 3 "$fake" --mode erase --no-encrypt /dev/x
    [[ "$output" != *unlock* ]]
    [[ "$output" == *'"disk"'* ]]
}
