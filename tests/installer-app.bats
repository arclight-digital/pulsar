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
    [ "$(py 'm.passphrase_problem("short", "short")')" = "At least 8 characters" ]
    [ "$(py 'm.passphrase_problem("correct horse", "correct hors")')" = "The two don't match" ]
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
    [ "$(py 'm.passphrase_hint("short", "")')" = "At least 8 characters" ]
    [ "$(py 'm.passphrase_hint("correct horse", "correct")')" = "The two don't match" ]
}

@test "the copy's progress fills the bar between its start and the boot setup" {
    [ "$(py 'round(m.install_fraction(0), 2), round(m.install_fraction(0.5), 2), round(m.install_fraction(1), 2), round(m.install_fraction(7), 2)')" = "(0.12, 0.53, 0.94, 0.94)" ]
}
