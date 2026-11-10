#!/usr/bin/env bats
# pulsar-install-disk against disk images: real systemd-repart, real LUKS, no
# root and no loop devices. Plans run on the image's real layouts against big
# sparse files; applies run on a copy of the layouts shrunk to fit in a few
# hundred MiB, because offline encryption writes every byte of the root.
#
# The alongside tests prove "Windows is untouched" by fingerprinting each of
# its partitions before and after. A fingerprint check that reads nothing
# passes vacuously, so the fixture refuses to start unless it sees four
# partitions with four DIFFERENT fingerprints, none of them the hash of empty
# input.

bats_require_minimum_version 1.5.0

EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
PASS='correct horse battery staple'

# The disk tests need the tools a real install uses. Where they aren't
# installed (a bare build-host container), say so and skip: every assertion
# still holds wherever they are. As root they work too (checked: 19/19 in a
# root Fedora container with them installed).
DISK_TOOLS="systemd-repart cryptsetup sfdisk mkfs.btrfs mkfs.vfat mkfs.ext4"
needs_disk_tools() {
    local t missing=""
    for t in $DISK_TOOLS; do command -v "$t" >/dev/null || missing="$missing $t"; done
    [ -z "$missing" ] || skip "needs$missing"
}

setup() {
    T="$BATS_TEST_TMPDIR"
    BIN="${BATS_TEST_DIRNAME}/../scripts/pulsar-install-disk"
    REAL="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/installer/repart"
    SMALL="$T/layouts"
    cp -r "$REAL" "$SMALL"
    sed -i 's/^SizeMinBytes=600M/SizeMinBytes=40M/; s/^SizeMaxBytes=600M/SizeMaxBytes=40M/' "$SMALL"/*/10-esp.conf
    sed -i 's/^SizeMinBytes=2G/SizeMinBytes=64M/; s/^SizeMaxBytes=2G/SizeMaxBytes=64M/' "$SMALL"/*/20-boot.conf
    sed -i 's/^SizeMinBytes=32G/SizeMinBytes=128M/' "$SMALL"/*/30-root.conf
    printf '%s' "$PASS" > "$T/key"
    chmod 600 "$T/key"
}

starts() {
    sfdisk -J "$1" | python3 -c 'import json,sys
for p in json.load(sys.stdin)["partitiontable"].get("partitions", []): print(p["start"])'
}

# sha256 of the first 1 MiB of every partition on the image, one per line
fingerprints() {
    local s
    for s in $(starts "$1"); do
        dd if="$1" bs=512 skip="$s" count=2048 status=none | sha256sum | cut -d' ' -f1
    done
}

# A Windows-shaped GPT disk: ESP, MSR, C:, free space, recovery at the end.
# $1 image, $2 size, $3 sector where recovery starts. Every partition gets
# 1 MiB of random data at its start so a fingerprint can tell them apart.
windows_disk() {
    truncate -s "$2" "$1"
    sfdisk -q "$1" <<EOF
label: gpt
start=2048, size=100MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI system partition"
size=16MiB, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name="Microsoft reserved partition"
size=${4:-30GiB}, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Basic data partition"
start=$3, size=8MiB, type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC, name="Recovery"
EOF
    local s
    for s in $(starts "$1"); do
        head -c 1M /dev/urandom | dd of="$1" bs=512 seek="$s" conv=notrunc status=none
    done
}

plan_types() {
    python3 -c 'import json,sys
for p in json.load(sys.stdin): print(p["type"], p["activity"])'
}

# the filesystem blkid finds at the start of partition $2: "btrfs" for an
# unencrypted root, "crypto_LUKS" for an encrypted one
part_type() {
    local s
    s=$(starts "$1" | sed -n "${2}p")
    dd if="$1" of="$T/part" bs=512 skip="$s" status=none
    blkid -p -o value -s TYPE "$T/part"
}

luks_opens_with() {
    local img=$1 n=$2 pass=$3 s
    s=$(starts "$img" | sed -n "${n}p")
    dd if="$img" of="$T/part" bs=512 skip="$s" status=none
    cryptsetup isLuks --type luks2 "$T/part" || return 1
    printf '%s' "$pass" | cryptsetup open --test-passphrase --key-file=- "$T/part"
}

@test "the fixture's fingerprints are real: four partitions, four different hashes, none empty" {
    needs_disk_tools
    windows_disk "$T/w.img" 64G 133000000
    run fingerprints "$T/w.img"
    [ "${#lines[@]}" -eq 4 ]
    [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 4 ]
    for l in "${lines[@]}"; do [ "$l" != "$EMPTY_SHA" ]; done
}

@test "erase: an empty disk gets ESP, /boot and an encrypted root (real layouts)" {
    needs_disk_tools
    truncate -s 64G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode erase "$T/d.img"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | plan_types | sort)" = "$(printf 'esp create\nroot-x86-64 create\nxbootldr create')" ]
}

@test "erase: the plan for a disk holding Windows replaces it, and planning writes nothing" {
    needs_disk_tools
    windows_disk "$T/w.img" 64G 133000000
    before=$(fingerprints "$T/w.img"; sfdisk -d "$T/w.img")
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode erase "$T/w.img"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | plan_types | sort)" = "$(printf 'esp create\nroot-x86-64 create\nxbootldr create')" ]
    [ "$(fingerprints "$T/w.img"; sfdisk -d "$T/w.img")" = "$before" ]
}

@test "erase: refuses a disk too small for the 32G root (real layouts)" {
    needs_disk_tools
    truncate -s 20G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode erase "$T/d.img"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *refused* ]]
}

@test "alongside: Windows keeps every partition; Pulsar takes the free space and shares the ESP (real layouts)" {
    needs_disk_tools
    windows_disk "$T/w.img" 128G 260000000
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/w.img"
    [ "$status" -eq 0 ]
    types=$(echo "$output" | plan_types | sort)
    [[ "$types" == *"esp unchanged"* ]]
    [[ "$types" == *"xbootldr create"* ]]
    [[ "$types" == *"root-x86-64 create"* ]]
    [ "$(echo "$types" | grep -c unchanged)" -eq 4 ]
    [ "$(echo "$types" | grep -c create)" -eq 2 ]
}

@test "alongside: refuses a disk with no EFI system partition instead of inventing one" {
    needs_disk_tools
    truncate -s 128G "$T/d.img"
    printf 'label: gpt\nsize=30GiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' | sfdisk -q "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/d.img"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"would create"* ]]
}

@test "alongside: refuses when the free space can't hold Pulsar" {
    needs_disk_tools
    windows_disk "$T/w.img" 64G 125000000 50GiB
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/w.img"
    [ "$status" -eq 2 ]
}

@test "alongside: refuses a blank disk (no partition table)" {
    needs_disk_tools
    truncate -s 128G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/d.img"
    [ "$status" -eq 2 ]
}

# A Linux laid out with the partition types Pulsar's own use (a Fedora, Arch
# or systemd-repart install): ESP, an XBOOTLDR /boot unless $4 is "-", a root
# of the discoverable root-x86-64 type, then free space. $1 image, $2 size,
# $3 root size. Random bytes at each start, as in windows_disk.
linux_disk() {
    truncate -s "$2" "$1"
    {
        echo "label: gpt"
        echo 'start=2048, size=100MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System Partition"'
        [ "${4:-}" = - ] || echo 'size=64MiB, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, name="boot"'
        echo "size=$3, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=\"root\""
    } | sfdisk -q "$1"
    local s
    for s in $(starts "$1"); do
        head -c 1M /dev/urandom | dd of="$1" bs=512 seek="$s" conv=notrunc status=none
    done
}

@test "alongside: another Linux's /boot and discoverable root are kept, not taken for Pulsar's (real layouts)" {
    needs_disk_tools
    linux_disk "$T/l.img" 128G 30GiB
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/l.img"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | plan_types | sort)" = "$(printf '%s\n' 'esp unchanged' 'root-x86-64 create' \
        'root-x86-64 unchanged' 'xbootldr create' 'xbootldr unchanged')" ]
    # the root made is Pulsar's, by its name; the one kept is the other Linux's
    [ "$(echo "$output" | jq -r '.[] | select(.activity == "create" and .type == "root-x86-64") | .label')" = pulsar ]
    [ "$(echo "$output" | jq -r '.[] | select(.activity == "unchanged" and .type == "root-x86-64") | .label')" = root ]
    # an ESP and a discoverable root, nothing else, is another system too
    linux_disk "$T/r.img" 128G 30GiB -
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/r.img"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | plan_types | sort)" = "$(printf '%s\n' 'esp unchanged' 'root-x86-64 create' \
        'root-x86-64 unchanged' 'xbootldr create')" ]
}

@test "apply alongside another Linux: its partitions are byte-for-byte and entry-for-entry unchanged" {
    needs_disk_tools
    linux_disk "$T/l.img" 1G 300MiB
    before=$(fingerprints "$T/l.img")
    [ "$(echo "$before" | sort -u | grep -vc "$EMPTY_SHA")" -eq 3 ]
    table_before=$(sfdisk -d "$T/l.img" | grep -E '^\S+[0-9] :')
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --key-file "$T/key" "$T/l.img"
    [ "$status" -eq 0 ]
    [ "$(sfdisk -d "$T/l.img" | grep -E '^\S+[0-9] :' | head -3)" = "$table_before" ]
    [ "$(fingerprints "$T/l.img" | head -3)" = "$before" ]
    [ "$(fingerprints "$T/l.img" | wc -l)" -eq 5 ]
    [ "$(sfdisk -J "$T/l.img" | jq -r '.partitiontable.partitions[4].name')" = pulsar ]
    luks_opens_with "$T/l.img" 5 "$PASS"
}

@test "alongside: a disk Pulsar is already on is refused, by its root's name" {
    needs_disk_tools
    # beside Windows, with room for another: a root named as Pulsar names its
    # own is Pulsar, whatever else is there
    windows_disk "$T/w.img" 128G 260000000
    printf 'size=2GiB, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, name="boot"\nsize=32GiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="pulsar"\n' |
        sfdisk -q --append "$T/w.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/w.img"
    [ "$status" -eq 2 ]
    [ "$stderr" = "pulsar-install-disk: refused: Pulsar is already on this disk (a root partition named pulsar): erase the disk to install it again" ]
}

@test "alongside: a disk with nothing but its ESP is refused, and the ESP isn't grown into the free space" {
    needs_disk_tools
    truncate -s 128G "$T/d.img"
    printf 'label: gpt\nsize=100MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' | sfdisk -q "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/d.img"
    [ "$status" -eq 2 ]
    [ "$stderr" = "pulsar-install-disk: refused: nothing to install alongside: the disk has only an EFI system partition" ]
}

@test "alongside: each held partition is pinned at exactly its size, and a plan that moves or grows one is refused" {
    # repart, run as root with an encrypted root, planned to grow a partition
    # held by Weight=0 alone into the free space after it (root-check image,
    # systemd 259): the placeholder must give the size itself
    run python3 - "$BIN" "$T/scratch" <<'PY'
import importlib.machinery as M, importlib.util as U, os, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
os.makedirs(sys.argv[2] + "/defs")
existing = [{"type": "root-x86-64", "label": "home", "uuid": "b", "partno": 3, "offset": 2 << 30, "raw_size": 8 << 30},
            {"type": "root-x86-64", "label": "root", "uuid": "a", "partno": 2, "offset": 1 << 30, "raw_size": 300 << 20},
            {"type": "esp", "label": "EFI", "uuid": "e", "partno": 0, "offset": 1 << 20, "raw_size": 100 << 20}]
out = m.hold_existing(sys.argv[2] + "/defs", existing, sys.argv[2])
for n in sorted(os.listdir(out)):
    print(n, open(os.path.join(out, n)).read().replace("\n", " "))
plan = [dict(e, activity="unchanged") for e in existing] + [
    {"type": "xbootldr", "activity": "create", "label": "boot", "uuid": "n1", "offset": 0, "raw_size": 0},
    {"type": "root-x86-64", "activity": "create", "label": "pulsar", "uuid": "n2", "offset": 0, "raw_size": 0}]
m.check("alongside", plan, existing)
print("as they were: allowed")
for change in ({"raw_size": 301 << 20}, {"offset": (1 << 30) + 4096}, {"activity": "resize"}):
    try:
        m.check("alongside", [dict(p, **change) if p["uuid"] == "a" else p for p in plan], existing)
        print(change, "allowed")
    except m.Refused as e:
        print(e)
PY
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' \
        "00-existing-root-x86-64-0.conf [Partition] Type=root-x86-64 SizeMinBytes=314572800 SizeMaxBytes=314572800 Weight=0 " \
        "00-existing-root-x86-64-1.conf [Partition] Type=root-x86-64 SizeMinBytes=8589934592 SizeMaxBytes=8589934592 Weight=0 " \
        "as they were: allowed" \
        "plan would move or resize partition root-x86-64 (root)" \
        "plan would move or resize partition root-x86-64 (root)" \
        "plan would resize partition root-x86-64 (root)")" ]
}

@test "alongside: a partition repart can't hold at its size (not a multiple of 4096 bytes) is refused, not resized" {
    needs_disk_tools
    # 300 MiB and one sector
    linux_disk "$T/l.img" 128G 614401
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside "$T/l.img"
    [ "$status" -eq 2 ]
    [ "$stderr" = "pulsar-install-disk: refused: partition root-x86-64 (root) is 314573312 bytes, not a multiple of 4096: systemd-repart can't keep it at that size" ]
}

@test "erase: a plan that keeps any partition is refused, whatever its type" {
    run python3 - "$BIN" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
new = [{"type": t, "activity": "create", "label": t} for t in ("esp", "xbootldr", "root-x86-64")]
for kept in ({"type": "root-x86-64", "activity": "unchanged", "label": "root"},
             {"type": "basic", "activity": "unchanged", "label": "Data"}):
    try:
        m.check("erase", new + [kept])
        print("allowed")
    except m.Refused as e:
        print(e)
PY
    [ "$output" = "$(printf '%s\n' 'an erase plan kept partition root-x86-64 (root)' 'an erase plan kept partition basic (Data)')" ]
}

@test "apply alongside: Windows' partitions are byte-for-byte and entry-for-entry unchanged" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 300MiB
    before=$(fingerprints "$T/w.img")
    [ "$(echo "$before" | sort -u | grep -vc "$EMPTY_SHA")" -eq 4 ]
    table_before=$(sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :' | head -4)
    [ "$(echo "$table_before" | wc -l)" -eq 4 ]
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    after=$(fingerprints "$T/w.img")
    [ "$(echo "$after" | wc -l)" -eq 6 ]
    # the first four are Windows', in table order: same entries, same bytes
    [ "$(sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :' | head -4)" = "$table_before" ]
    [ "$(echo "$after" | head -4)" = "$before" ]
}

@test "apply alongside: the new root is LUKS2 and opens with the passphrase, not without it" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 300MiB
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    luks_opens_with "$T/w.img" 6 "$PASS"
    ! luks_opens_with "$T/w.img" 6 "wrong passphrase"
}

@test "apply erase: three partitions, encrypted root opens with the passphrase" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 600MiB
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    [ "$(starts "$T/w.img" | wc -l)" -eq 3 ]
    luks_opens_with "$T/w.img" 3 "$PASS"
    ! luks_opens_with "$T/w.img" 3 "wrong passphrase"
}

@test "apply needs --key-file or --no-encrypt: neither is never taken as unencrypted" {
    needs_disk_tools
    truncate -s 1G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase "$T/d.img"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--key-file (encrypted) or --no-encrypt"* ]]
    [ "$(starts "$T/d.img" | wc -l)" -eq 0 ]
}

@test "--key-file and --no-encrypt together are refused, and nothing is written" {
    needs_disk_tools
    truncate -s 1G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --key-file "$T/key" --no-encrypt "$T/d.img"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"not allowed with"* ]]
    [ "$(starts "$T/d.img" | wc -l)" -eq 0 ]
}

# definitions(): the layout directory repart is given, by choice
defs_py() {
    PULSAR_INSTALLER_LAYOUTS="$1" python3 - "$BIN" "$2" "$3" "$T/scratch" <<'PY'
import importlib.machinery as M, importlib.util as U, os, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
os.makedirs(sys.argv[4], exist_ok=True)
try:
    print(m.definitions(sys.argv[2], sys.argv[3] == "encrypt", sys.argv[4]))
except m.Refused as e:
    print("REFUSED", e); sys.exit(2)
PY
}

@test "layouts: encrypted is the shipped one; unencrypted is a copy without the Encrypt= line and nothing else changed" {
    for mode in erase alongside; do
        run defs_py "$REAL" "$mode" encrypt
        [ "$status" -eq 0 ]
        [ "$output" = "$REAL/$mode" ]
        rm -rf "$T/scratch"
        run defs_py "$REAL" "$mode" plain
        [ "$status" -eq 0 ]
        [ "$output" = "$T/scratch/$mode" ]
        ! grep -rq '^Encrypt=' "$output"
        # the root's one difference is the Encrypt= line; the rest is identical
        [ "$(diff "$REAL/$mode/30-root.conf" "$output/30-root.conf" | grep '^[<>]')" = "< Encrypt=key-file" ]
        diff "$REAL/$mode/10-esp.conf" "$output/10-esp.conf"
        diff "$REAL/$mode/20-boot.conf" "$output/20-boot.conf"
        # and the shipped layout still encrypts
        grep -qx 'Encrypt=key-file' "$REAL/$mode/30-root.conf"
    done
}

@test "layouts: a shipped root that doesn't encrypt is refused either way, never installed as if encrypted" {
    sed -i '/^Encrypt=/d' "$SMALL/erase/30-root.conf"
    run defs_py "$SMALL" erase encrypt
    [ "$status" -eq 2 ]
    [[ "$output" == *"exactly one Encrypt=key-file"* ]]
    run defs_py "$SMALL" erase plain
    [ "$status" -eq 2 ]
}

@test "unencrypted erase: plan creates the same three partitions (real layouts)" {
    needs_disk_tools
    truncate -s 64G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode erase --no-encrypt "$T/d.img"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | plan_types | sort)" = "$(printf 'esp create\nroot-x86-64 create\nxbootldr create')" ]
}

@test "unencrypted alongside: plan keeps all four Windows partitions and shares the ESP (real layouts)" {
    needs_disk_tools
    windows_disk "$T/w.img" 128G 260000000
    PULSAR_INSTALLER_LAYOUTS="$REAL" run --separate-stderr "$BIN" plan --mode alongside --no-encrypt "$T/w.img"
    [ "$status" -eq 0 ]
    types=$(echo "$output" | plan_types | sort)
    [[ "$types" == *"esp unchanged"* ]]
    [ "$(echo "$types" | grep -c unchanged)" -eq 4 ]
    [ "$(echo "$types" | grep -c create)" -eq 2 ]
}

@test "apply erase --no-encrypt: three partitions, the root is plain btrfs, not LUKS" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 600MiB
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --no-encrypt "$T/w.img"
    [ "$status" -eq 0 ]
    [ "$(starts "$T/w.img" | wc -l)" -eq 3 ]
    [ "$(part_type "$T/w.img" 3)" = "btrfs" ]
    ! cryptsetup isLuks "$T/part"
}

@test "apply erase --key-file: the root is LUKS, not plain btrfs" {
    needs_disk_tools
    truncate -s 1G "$T/d.img"
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --key-file "$T/key" "$T/d.img"
    [ "$status" -eq 0 ]
    [ "$(part_type "$T/d.img" 3)" = "crypto_LUKS" ]
}

@test "apply alongside --no-encrypt: Windows byte-for-byte unchanged, the new root plain btrfs" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 300MiB
    before=$(fingerprints "$T/w.img")
    table_before=$(sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :' | head -4)
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --no-encrypt "$T/w.img"
    [ "$status" -eq 0 ]
    after=$(fingerprints "$T/w.img")
    [ "$(echo "$after" | wc -l)" -eq 6 ]
    [ "$(sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :' | head -4)" = "$table_before" ]
    [ "$(echo "$after" | head -4)" = "$before" ]
    [ "$(part_type "$T/w.img" 6)" = "btrfs" ]
}

@test "two installs never share a partition table, partition or LUKS UUID" {
    needs_disk_tools
    # repart derives UUIDs from the machine ID unless told otherwise, and
    # every boot of one live ISO has the same machine ID
    for n in 1 2; do
        truncate -s 1G "$T/d$n.img"
        PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --key-file "$T/key" "$T/d$n.img"
        [ "$status" -eq 0 ]
    done
    ids() { sfdisk -J "$1" | python3 -c 'import json,sys
t = json.load(sys.stdin)["partitiontable"]
print(t["id"]); [print(p["uuid"]) for p in t["partitions"]]'; }
    luks() { local s; s=$(starts "$1" | sed -n 3p); dd if="$1" of="$T/p" bs=512 skip="$s" count=32768 status=none; cryptsetup luksUUID "$T/p"; }
    a=$( (ids "$T/d1.img"; luks "$T/d1.img") | sort)
    b=$( (ids "$T/d2.img"; luks "$T/d2.img") | sort)
    [ "$(echo "$a" | wc -l)" -eq 5 ]
    [ -z "$(comm -12 <(echo "$a") <(echo "$b"))" ]
}

# pulsar-install-system's clean-up after a failed install, which needs no
# root: it only edits the partition table
remove_made() {
    python3 - "$@" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
m.subprocess.run = (lambda real: lambda c, *a, **k: real(c, *a, **k) if c[0] != "udevadm" else None)(m.subprocess.run)
print("\n".join(m.remove_made(sys.argv[2], set(sys.argv[3:]))))
PY
}

@test "a failed alongside install takes back its partitions: Windows as it was, and a retry works" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 300MiB
    before=$(fingerprints "$T/w.img"; sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :')
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    made=$(echo "$output" | python3 -c 'import json,sys
print(" ".join(p["uuid"] for p in json.load(sys.stdin) if p["activity"] == "create"))')
    [ "$(echo $made | wc -w)" -eq 2 ]
    # (the install would now fail in bootc; this is its clean-up)
    run --separate-stderr remove_made "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$T/w.img" $made
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 2 ]
    [ "$(fingerprints "$T/w.img"; sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :')" = "$before" ]
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
}

@test "clean-up removes only the partitions it was given, never another system's or an older Pulsar's" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 300MiB
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode alongside --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    before=$(sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :')
    [ "$(echo "$before" | wc -l)" -eq 6 ]
    # UUIDs that are on no partition of this disk: nothing goes
    run --separate-stderr remove_made "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$T/w.img" \
        00000000-0000-0000-0000-000000000001 "$(cat /proc/sys/kernel/random/uuid)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(sfdisk -d "$T/w.img" | grep -E '^\S+[0-9] :')" = "$before" ]
}

# write_locale: no root, a stand-in deployment tree
locale_py() {
    python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$@" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
try:
    print(m.write_locale(sys.argv[2], sys.argv[3], sys.argv[4]))
except m.Failed as e:
    print("FAILED", e); sys.exit(1)
PY
}

@test "the installed system gets the language and keymap, in its one deployment's /etc" {
    mkdir -p "$T/t/ostree/deploy/default/deploy/abc123.0/etc"
    touch "$T/t/ostree/deploy/default/deploy/abc123.0.origin"
    run locale_py "$T/t" de_DE.UTF-8 de
    [ "$status" -eq 0 ]
    [ "$(cat "$T/t/ostree/deploy/default/deploy/abc123.0/etc/locale.conf")" = 'LANG="de_DE.UTF-8"' ]
    [ "$(cat "$T/t/ostree/deploy/default/deploy/abc123.0/etc/vconsole.conf")" = 'KEYMAP=de' ]
}

@test "two deployments (or none): refuse rather than guess which /etc" {
    mkdir -p "$T/t/ostree/deploy/default/deploy/a.0/etc" "$T/t/ostree/deploy/default/deploy/b.0/etc"
    run locale_py "$T/t" en_US.UTF-8 us
    [ "$status" -eq 1 ]
    [[ "$output" == *"found 2"* ]]
}

@test "a live system on the bare C locale gives the install en_US, not C (Initial Setup shows C as 'Unspecified')" {
    for lang in C C.UTF-8 POSIX en_US.UTF-8 de_DE.UTF-8; do
        printf 'LANG="%s"\n' "$lang" > "$T/locale.conf"
        run python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$T/locale.conf" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
print(m.live_lang(sys.argv[2]))
PY
        case $lang in C|C.UTF-8|POSIX) [ "$output" = "en_US.UTF-8" ] ;; *) [ "$output" = "$lang" ] ;; esac
    done
}

@test "apply: repart's own log reaches stderr as it works, and stdout stays the plan" {
    needs_disk_tools
    windows_disk "$T/w.img" 1G 2000000 600MiB
    PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    # what the installer shows under the bar while the disk is being set up
    [[ "$stderr" == *"partition"* ]]
    [ "$(echo "$output" | plan_types | sort)" = "$(printf 'esp create\nroot-x86-64 create\nxbootldr create')" ]
}

@test "apply: mkfs.btrfs never TRIMs the root again after repart has (it went through loop and LUKS)" {
    needs_disk_tools
    # the real repart, with a mkfs.btrfs in front of the real one that notes
    # how it was called
    mkdir -p "$T/shim"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec %s "$@"\n' "$T/mkfs-args" "$(command -v mkfs.btrfs)" \
        > "$T/shim/mkfs.btrfs"
    chmod +x "$T/shim/mkfs.btrfs"
    windows_disk "$T/w.img" 1G 2000000 600MiB
    PATH="$T/shim:$PATH" PULSAR_INSTALLER_LAYOUTS="$SMALL" run --separate-stderr "$BIN" apply --mode erase --key-file "$T/key" "$T/w.img"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$T/mkfs-args")" -eq 1 ]
    grep -q -- '--nodiscard' "$T/mkfs-args"
}

@test "the disk step's log is shown line by line as it comes, its output kept, its failure named" {
    run --separate-stderr python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" <<'PY'
import importlib.machinery as M, importlib.util as U, sys, time
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
t0, seen = time.monotonic(), []
m.emit = lambda **e: seen.append((e["log"], round(time.monotonic() - t0)))
out = m.run_logged("sh", "-c", 'echo "Encrypting future partition 3..." >&2; sleep 2; '
                               'echo "Formatting future partition 3." >&2; echo "[1]"')
print(seen, out.strip())
try:
    m.run_logged("sh", "-c", 'echo "Device busy" >&2; exit 4')
except m.Failed as e:
    print(e)
PY
    [ "$status" -eq 0 ]
    # the first line arrived before the step's two seconds were up, not at its end
    [ "${lines[0]}" = "[('Encrypting future partition 3...', 0), ('Formatting future partition 3.', 2)] [1]" ]
    [ "${lines[1]}" = "sh exited 4: Device busy" ]
}

@test "copy progress: bootc's announced size, and what has landed against it, never past 0.99" {
    run python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
print(m.payload_bytes("layers already present: 0; layers needed: 201 (7.8\u00a0GB)"))
print(m.payload_bytes("layers already present: 3; layers needed: 12 (512 MB)"))
print(m.payload_bytes("Fetching layer sha256:abc"))
G = 10**9
print(m.copied_fraction(1 * G, 1 * G, 7.8 * G), m.copied_fraction(4.9 * G, 1 * G, 7.8 * G),
      m.copied_fraction(20 * G, 1 * G, 7.8 * G), m.copied_fraction(3 * G, 1 * G, None))
PY
    [ "$status" -eq 0 ]
    # bootc's own line, with its no-break space: a plain space hid this
    [ "${lines[0]}" = "7800000000" ]
    [ "${lines[1]}" = "512000000" ]
    [ "${lines[2]}" = "None" ]
    [ "${lines[3]}" = "0.0 0.5 0.99 0.0" ]
}

@test "boot: the passphrase prompt gets the installer's keymap, and the desktop its layout" {
    run python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$T" <<'PY'
import importlib.machinery as M, importlib.util as U, os, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
print(" ".join(m.boot_kargs("abc", "de-latin1-nodeadkeys")))
etc = os.path.join(sys.argv[2], "t/ostree/deploy/default/deploy/x.0/etc"); os.makedirs(etc)
m.write_locale(os.path.join(sys.argv[2], "t"), "de_DE.UTF-8", "de-latin1-nodeadkeys", "de", "nodeadkeys")
print(open(os.path.join(etc, "vconsole.conf")).read().replace("\n", ";"))
PY
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rd.luks.uuid=abc rhgb quiet rd.vconsole.keymap=de-latin1-nodeadkeys" ]
    [ "${lines[1]}" = "KEYMAP=de-latin1-nodeadkeys;XKBLAYOUT=de;XKBVARIANT=nodeadkeys;" ]
}

@test "boot: an unencrypted root gets no rd.luks argument, and keeps the rest" {
    run python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
print(" ".join(m.boot_kargs(None, "us", ["foo=1"])))
PY
    [ "$status" -eq 0 ]
    [ "$output" = "rhgb quiet rd.vconsole.keymap=us foo=1" ]
}

# pulsar-install-system's main() with every outside command stubbed: run()
# and run_logged() print what the disk tool was asked and stop there, so nothing is
# partitioned, opened or mounted; any other command fails the test.
system_py() {
    python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$T" "$@" 2>&1 <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
m.os.geteuid = lambda: 0
m.SCRATCH = sys.argv[2] + "/run"
def run(*cmd, **kw):
    if cmd[0] == m.DISK_TOOL:
        print("DISK", " ".join(cmd[1:]))
        raise m.Failed("stopped by the test")
    raise SystemExit(f"unexpected command {cmd}")
def nothing(*a, **k):
    raise SystemExit(f"unexpected command {a}")
m.run = m.run_logged = run
m.subprocess.run = m.subprocess.Popen = nothing
m.emit = lambda **e: None
sys.argv = ["pulsar-install-system"] + sys.argv[3:]
sys.exit(m.main())
PY
}

@test "install-system: --key-file and --no-encrypt are exclusive, and installing needs one of them" {
    run system_py --mode erase --key-file "$T/key" --no-encrypt --source-imgref a --target-imgref b /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"not allowed with"* ]]
    [[ "$output" != *DISK* ]]
    run system_py --mode erase --source-imgref a --target-imgref b /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"--key-file (or --no-encrypt)"* ]]
    [[ "$output" != *DISK* ]]
}

@test "install-system passes the choice to the disk tool: --no-encrypt, or the key file" {
    run system_py --mode erase --no-encrypt --source-imgref a --target-imgref b --expect-size 1 --expect-serial X /dev/fake
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISK apply --mode erase --no-encrypt --expect-size 1 --expect-serial X /dev/fake"* ]]
    run system_py --mode erase --key-file "$T/key" --source-imgref a --target-imgref b --expect-size 1 --expect-serial X /dev/fake
    [ "$status" -eq 1 ]
    [[ "$output" == *"DISK apply --mode erase --key-file $T/key --expect-size 1 --expect-serial X /dev/fake"* ]]
    run system_py --mode erase --plan-only --no-encrypt /dev/fake
    [[ "$output" == *"DISK plan --mode erase --no-encrypt /dev/fake"* ]]
    run system_py --mode erase --plan-only /dev/fake
    [[ "$output" == *"DISK plan --mode erase /dev/fake"* ]]
}
