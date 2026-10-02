#!/usr/bin/env bats
# pulsar-esp-fallback: on an ESP shared with Windows, EFI/BOOT/BOOTX64.EFI
# stays Windows'. Plain folders stand in for the ESP and the saved copy.

setup() {
    BIN="${BATS_TEST_DIRNAME}/../scripts/pulsar-esp-fallback"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/esp/EFI/BOOT" "$T/saved" "$T/shim"
    printf 'WINDOWS-BOOTMGR-v1' > "$T/saved/BOOTX64.EFI"
    printf 'PULSAR-SHIM-16.1' > "$T/shim/BOOTX64.EFI"
}

@test "bootupd put Pulsar's shim there: Windows' file goes back" {
    cp "$T/shim/BOOTX64.EFI" "$T/esp/EFI/BOOT/BOOTX64.EFI"
    run "$BIN" check "$T/esp" "$T/saved" "$T/shim/BOOTX64.EFI"
    [ "$output" = "restored" ]
    [ "$(cat "$T/esp/EFI/BOOT/BOOTX64.EFI")" = "WINDOWS-BOOTMGR-v1" ]
}

@test "Windows updated its own file: it's adopted as the saved copy, not reverted" {
    printf 'WINDOWS-BOOTMGR-v2' > "$T/esp/EFI/BOOT/BOOTX64.EFI"
    run "$BIN" check "$T/esp" "$T/saved" "$T/shim/BOOTX64.EFI"
    [ "$output" = "adopted" ]
    [ "$(cat "$T/esp/EFI/BOOT/BOOTX64.EFI")" = "WINDOWS-BOOTMGR-v2" ]
    [ "$(cat "$T/saved/BOOTX64.EFI")" = "WINDOWS-BOOTMGR-v2" ]
}

@test "already Windows': nothing touched" {
    cp "$T/saved/BOOTX64.EFI" "$T/esp/EFI/BOOT/BOOTX64.EFI"
    run "$BIN" check "$T/esp" "$T/saved" "$T/shim/BOOTX64.EFI"
    [ "$output" = "kept" ]
}

@test "an install that saved nothing (erase, or no Windows): never touches the ESP" {
    rm "$T/saved/BOOTX64.EFI"
    cp "$T/shim/BOOTX64.EFI" "$T/esp/EFI/BOOT/BOOTX64.EFI"
    run "$BIN" check "$T/esp" "$T/saved" "$T/shim/BOOTX64.EFI"
    [ "$output" = "nothing saved" ]
    [ "$(cat "$T/esp/EFI/BOOT/BOOTX64.EFI")" = "PULSAR-SHIM-16.1" ]
}

@test "without the image's shims to compare with, it changes nothing" {
    cp "$T/shim/BOOTX64.EFI" "$T/esp/EFI/BOOT/BOOTX64.EFI"
    run "$BIN" check "$T/esp" "$T/saved" "$T/nope/BOOTX64.EFI"
    [[ "$output" == kept* ]]
    [ "$(cat "$T/esp/EFI/BOOT/BOOTX64.EFI")" = "PULSAR-SHIM-16.1" ]
}

# the installer's half: pulsar-install-system's snapshot and restore
fallback_py() {
    python3 - "${BATS_TEST_DIRNAME}/../scripts/pulsar-install-system" "$@" <<'PY'
import importlib.machinery as M, importlib.util as U, sys
l = M.SourceFileLoader("m", sys.argv[1]); m = U.module_from_spec(U.spec_from_loader("m", l)); l.exec_module(m)
esp, saved = sys.argv[2], sys.argv[3]
snap = m.snapshot_fallback(esp)
# what bootupd's install does to EFI/BOOT
import os
os.makedirs(os.path.join(esp, "EFI/BOOT"), exist_ok=True)
for n, data in (("BOOTX64.EFI", b"PULSAR-SHIM"), ("fbx64.efi", b"FB"), ("BOOTIA32.EFI", b"IA32")):
    open(os.path.join(esp, "EFI/BOOT", n), "wb").write(data)
m.restore_fallback(esp, snap, saved)
PY
}

@test "install beside Windows: EFI/BOOT is exactly as Windows left it, and its loader is saved" {
    printf 'WINDOWS-BOOTMGR' > "$T/esp/EFI/BOOT/BOOTX64.EFI"
    run fallback_py "$T/esp" "$T/kept"
    [ "$status" -eq 0 ]
    [ "$(ls "$T/esp/EFI/BOOT")" = "BOOTX64.EFI" ]
    [ "$(cat "$T/esp/EFI/BOOT/BOOTX64.EFI")" = "WINDOWS-BOOTMGR" ]
    [ "$(cat "$T/kept/BOOTX64.EFI")" = "WINDOWS-BOOTMGR" ]
}

@test "install beside a system with no fallback at all: bootupd's EFI/BOOT is taken away again" {
    rmdir "$T/esp/EFI/BOOT"
    run fallback_py "$T/esp" "$T/kept"
    [ "$status" -eq 0 ]
    [ ! -e "$T/esp/EFI/BOOT" ]
    [ ! -e "$T/kept/BOOTX64.EFI" ]
}
