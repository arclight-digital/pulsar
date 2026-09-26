#!/usr/bin/env bats
# Tests for scripts/gl-nvidia.sh.
#
# The bug these exist for: on 2026-09-26 cherenkov booted a new image with a
# new NVIDIA driver, Steam autostarted, and the matching
# GL.nvidia-<version> Flatpak extension arrived 16 seconds later. That Steam
# had no NVIDIA driver, and its games rendered black on the iGPU. The script
# installs the extension when the update is STAGED, reading the version out
# of the staged tree's manifest, so it is present before the reboot.
#
# Pinned here: the staged driver is fetched, not only the booted one; GL32
# comes along only when something 32-bit is installed; nothing that is
# present is fetched again; an extension flathub has not published yet is not
# a failure (retrying would loop forever), while a real install failure is.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/gl-nvidia.sh"

    export PULSAR_NVIDIA_VERSION_FILE="${BATS_TEST_TMPDIR}/nvidia-version"
    export PULSAR_SYSROOT="${BATS_TEST_TMPDIR}/sysroot"
    printf '610.57.04\n' > "$PULSAR_NVIDIA_VERSION_FILE"

    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export FLATPAK_STATE="${BATS_TEST_TMPDIR}/installed"
    export FLATPAK_LOG="${BATS_TEST_TMPDIR}/install.log"
    export FLATPAK_UNPUBLISHED="" FLATPAK_OFFLINE=""
    : > "$FLATPAK_STATE"; : > "$FLATPAK_LOG"

    cat > "${STUB}/flatpak" <<'EOF'
#!/bin/sh
case "$1" in
    list)    cat "$FLATPAK_STATE"; exit 0 ;;
    remotes) printf 'flathub\nfedora\n'; exit 0 ;;
    install)
        for a in "$@"; do ref="$a"; done
        [ -n "$FLATPAK_OFFLINE" ] && { echo "error: Could not resolve host: dl.flathub.org" >&2; exit 1; }
        case " $FLATPAK_UNPUBLISHED " in *" $ref "*)
            echo "error: Nothing matches $ref in remote flathub" >&2; exit 1 ;;
        esac
        echo "$ref" >> "$FLATPAK_LOG"; echo "$ref" >> "$FLATPAK_STATE"; exit 0 ;;
    uninstall)
        for a in "$@"; do ref="$a"; done
        echo "-$ref" >> "$FLATPAK_LOG"
        grep -vFx "$ref" "$FLATPAK_STATE" > "$FLATPAK_STATE.n"; mv "$FLATPAK_STATE.n" "$FLATPAK_STATE"
        exit 0 ;;
esac
exit 1
EOF
    chmod +x "${STUB}/flatpak"
    PATH="${STUB}:${PATH}"
    export PATH
}

# A deployment on disk whose manifest names driver $1 ($2 = its checksum).
# Read off disk, not asked of rpm-ostree: the daemon can lag the staged
# marker that starts the unit.
stage() {
    local dir="${PULSAR_SYSROOT}/ostree/deploy/fedora/deploy/${2:-abc123}.0/usr/share/pulsar"
    mkdir -p "$dir"
    printf '{"variant":"nvidia-open","nvidia_driver":"%s"}\n' "$1" > "${dir}/manifest.json"
}

@test "REGRESSION: the staged update's driver extension is fetched before the reboot" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_LOG"
    [ "$output" = "org.freedesktop.Platform.GL.nvidia-615-71-09" ]
}

@test "the booted driver's extension is fetched when it is missing" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx org.freedesktop.Platform.GL.nvidia-610-57-04 "$FLATPAK_LOG"
}

@test "GL32 comes along when a 32-bit compat runtime is installed" {
    echo org.freedesktop.Platform.Compat.i386 > "$FLATPAK_STATE"
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx org.freedesktop.Platform.GL32.nvidia-615-71-09 "$FLATPAK_LOG"
    grep -qx org.freedesktop.Platform.GL32.nvidia-610-57-04 "$FLATPAK_LOG"
}

@test "no GL32 without anything 32-bit to load it" {
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep GL32 "$FLATPAK_LOG"
    [ "$status" -ne 0 ]
}

@test "everything present means no install and no network" {
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    export FLATPAK_OFFLINE=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FLATPAK_LOG" ]
}

@test "an extension flathub has not published yet is not a failure" {
    stage 999.1.2
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    export FLATPAK_UNPUBLISHED=org.freedesktop.Platform.GL.nvidia-999-1-2
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not on flathub yet"* ]]
}

@test "a real install failure exits nonzero so the unit retries" {
    export FLATPAK_OFFLINE=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"will retry"* ]]
}

@test "a driver version that is not version-shaped is ignored, not installed" {
    printf 'package kmod-nvidia-open is not installed\n' > "$PULSAR_NVIDIA_VERSION_FILE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FLATPAK_LOG" ]
    [[ "$output" == *"nothing to do"* ]]
}

@test "a deployment with no manifest falls back to the booted driver" {
    mkdir -p "${PULSAR_SYSROOT}/ostree/deploy/fedora/deploy/nomanifest.0/usr"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx org.freedesktop.Platform.GL.nvidia-610-57-04 "$FLATPAK_LOG"
}

@test "extensions for drivers no deployment carries are removed" {
    printf '%s\n' org.freedesktop.Platform.Compat.i386 \
        org.freedesktop.Platform.GL.nvidia-595-80 \
        org.freedesktop.Platform.GL.nvidia-610-57-04 org.freedesktop.Platform.GL32.nvidia-610-57-04 \
        org.freedesktop.Platform.GL.nvidia-615-71-09 org.freedesktop.Platform.GL32.nvidia-615-71-09 \
        org.freedesktop.Platform.GL.default > "$FLATPAK_STATE"
    stage 610.57.04 rollback     # the rollback deployment's driver stays
    stage 615.71.09 staged
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_LOG"
    [ "$output" = "-org.freedesktop.Platform.GL.nvidia-595-80" ]
    grep -qx org.freedesktop.Platform.GL.default "$FLATPAK_STATE"
}

@test "nothing is removed when the new driver's extension could not be installed" {
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-595-80 > "$FLATPAK_STATE"
    export FLATPAK_OFFLINE=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -qx org.freedesktop.Platform.GL.nvidia-595-80 "$FLATPAK_STATE"
}

@test "no stale extensions is a clean run, not a pipefail exit" {
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}
