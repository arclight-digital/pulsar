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
#
# And the second bug, 2026-10-07: GNOME Software deployed a flathub rebuild
# of the running driver's extension 34 seconds after Steam autostarted, and
# Steam lost its driver the same way. Pinned: every installed NVIDIA GL
# extension is masked, so no update swaps it; a newer build goes in only when
# no running app holds it, and waits (downloaded) when one does.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/gl-nvidia.sh"

    export PULSAR_NVIDIA_VERSION_FILE="${BATS_TEST_TMPDIR}/nvidia-version"
    export PULSAR_SYSROOT="${BATS_TEST_TMPDIR}/sysroot"
    printf '610.57.04\n' > "$PULSAR_NVIDIA_VERSION_FILE"

    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export FLATPAK_STATE="${BATS_TEST_TMPDIR}/installed"
    export FLATPAK_LOG="${BATS_TEST_TMPDIR}/install.log"
    # "<ref> <commit>" lines, the last for a ref winning: the build deployed,
    # and the build flathub has (by default the same one)
    export FLATPAK_COMMITS="${BATS_TEST_TMPDIR}/commits"
    export FLATPAK_REMOTE="${BATS_TEST_TMPDIR}/remote"
    export FLATPAK_MASKS="${BATS_TEST_TMPDIR}/masks"
    export PULSAR_RUN_ROOT="${BATS_TEST_TMPDIR}/run"
    export FLATPAK_UNPUBLISHED="" FLATPAK_OFFLINE=""
    : > "$FLATPAK_STATE"; : > "$FLATPAK_LOG"
    : > "$FLATPAK_COMMITS"; : > "$FLATPAK_REMOTE"; : > "$FLATPAK_MASKS"

    cat > "${STUB}/flatpak" <<'EOF'
#!/bin/sh
cmd=$1; shift
ref="" reinstall="" nodeploy="" nopull="" remove=""
for a in "$@"; do
    case "$a" in
        --reinstall) reinstall=1 ;;
        --no-deploy) nodeploy=1 ;;
        --no-pull)   nopull=1 ;;
        --remove)    remove=1 ;;
        -*) ;;
        *) ref="$a" ;;
    esac
done
commit() { awk -v r="$1" '$1 == r { v = $2 } END { if (v == "") exit 1; print v }' "$2"; }
case "$cmd" in
    list)    cat "$FLATPAK_STATE"; exit 0 ;;
    remotes) printf 'flathub\nfedora\n'; exit 0 ;;
    info)
        grep -qFx "$ref" "$FLATPAK_STATE" || exit 1
        commit "$ref" "$FLATPAK_COMMITS" || echo c0
        exit 0 ;;
    remote-info)
        [ -n "$FLATPAK_OFFLINE" ] && { echo "error: Could not resolve host: dl.flathub.org" >&2; exit 1; }
        commit "$ref" "$FLATPAK_REMOTE" || commit "$ref" "$FLATPAK_COMMITS" || echo c0
        exit 0 ;;
    mask)
        [ -z "$ref" ] && { sed 's/^/  /' "$FLATPAK_MASKS"; exit 0; }
        if [ -n "$remove" ]; then
            grep -qFx "$ref" "$FLATPAK_MASKS" || { echo "error: No current masked pattern matching $ref" >&2; exit 1; }
            grep -vFx "$ref" "$FLATPAK_MASKS" > "$FLATPAK_MASKS.n"; mv "$FLATPAK_MASKS.n" "$FLATPAK_MASKS"
            exit 0
        fi
        grep -qFx "$ref" "$FLATPAK_MASKS" || echo "$ref" >> "$FLATPAK_MASKS"
        exit 0 ;;
    install)
        [ -n "$FLATPAK_OFFLINE" ] && [ -z "$nopull" ] && { echo "error: Could not resolve host: dl.flathub.org" >&2; exit 1; }
        if [ -n "$reinstall" ] && [ -n "$nodeploy" ]; then
            echo "pull:$ref" >> "$FLATPAK_LOG"; exit 0
        fi
        if [ -n "$reinstall" ] && [ -n "$nopull" ]; then
            echo "deploy:$ref" >> "$FLATPAK_LOG"
            echo "$ref $(commit "$ref" "$FLATPAK_REMOTE")" >> "$FLATPAK_COMMITS"; exit 0
        fi
        case " $FLATPAK_UNPUBLISHED " in *" $ref "*)
            echo "error: Nothing matches $ref in remote flathub" >&2; exit 1 ;;
        esac
        echo "$ref" >> "$FLATPAK_LOG"; echo "$ref" >> "$FLATPAK_STATE"; exit 0 ;;
    uninstall)
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
    # Shown only if this fails: it failed once on the build host (2026-10-03)
    # and nowhere else, with nothing to say whether GL32 or 615 went missing.
    printf 'script said:\n%s\nflatpak list:\n' "$output"; cat "$FLATPAK_STATE"
    echo "installed:"; cat "$FLATPAK_LOG"
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

# A running instance of app $1 (pid $2) that mounted extension $3.
instance() {
    local dir="${PULSAR_RUN_ROOT}/1000/.flatpak/${RANDOM}${RANDOM}"
    mkdir -p "$dir"
    printf '[Application]\nname=%s\n\n[Instance]\nruntime-extensions=org.freedesktop.Platform.GL.default=aaa;%s=c0\n' \
        "$1" "$3" > "${dir}/info"
    echo "$2" > "${dir}/pid"
}

# a pid that is certainly not running
dead_pid() {
    sh -c 'exit 0' &
    local p=$!
    wait "$p"
    echo "$p"
}

@test "REGRESSION: every installed NVIDIA GL extension is masked, so no update swaps it under an app" {
    printf '%s\n' org.freedesktop.Platform.Compat.i386 org.freedesktop.Platform.GL.default \
        org.freedesktop.Platform.GL.nvidia-610-57-04 org.freedesktop.Platform.GL32.nvidia-610-57-04 > "$FLATPAK_STATE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx org.freedesktop.Platform.GL.nvidia-610-57-04 "$FLATPAK_MASKS"
    grep -qx org.freedesktop.Platform.GL32.nvidia-610-57-04 "$FLATPAK_MASKS"
    # only those: a pattern would stop a new driver's extension installing
    [ "$(wc -l < "$FLATPAK_MASKS")" -eq 2 ]
}

@test "an extension installed for a new driver is masked too" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx org.freedesktop.Platform.GL.nvidia-615-71-09 "$FLATPAK_MASKS"
}

@test "a newer build of the running driver's extension goes in when no app holds it" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    instance com.valvesoftware.Steam "$(dead_pid)" org.freedesktop.Platform.GL.nvidia-610-57-04
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_LOG"
    [ "$output" = "$(printf 'pull:%s\ndeploy:%s' org.freedesktop.Platform.GL.nvidia-610-57-04 org.freedesktop.Platform.GL.nvidia-610-57-04)" ]
}

@test "REGRESSION: a newer build waits, downloaded, while a running app holds the extension" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    instance com.valvesoftware.Steam $$ org.freedesktop.Platform.GL.nvidia-610-57-04
    instance com.discordapp.Discord $$ org.freedesktop.Platform.GL.nvidia-610-57-04
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam, Discord use the current one"* ]]
    grep -qx pull:org.freedesktop.Platform.GL.nvidia-610-57-04 "$FLATPAK_LOG"
    run grep deploy: "$FLATPAK_LOG"
    [ "$status" -ne 0 ]
}

@test "a running app holding another driver's extension does not hold back this one" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    instance com.valvesoftware.Steam $$ org.freedesktop.Platform.GL.nvidia-610-57-04-1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx deploy:org.freedesktop.Platform.GL.nvidia-610-57-04 "$FLATPAK_LOG"
}

@test "only the running driver's extensions are refreshed" {
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-610-57-04 org.freedesktop.Platform.GL.nvidia-615-71-09 > "$FLATPAK_STATE"
    stage 615.71.09
    echo "org.freedesktop.Platform.GL.nvidia-615-71-09 c1" > "$FLATPAK_REMOTE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FLATPAK_LOG" ]
}

@test "a refresh that cannot reach flathub is not a failure" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    export FLATPAK_OFFLINE=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FLATPAK_LOG" ]
}

@test "a removed extension loses its mask" {
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-595-80 org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-595-80 > "$FLATPAK_MASKS"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -x org.freedesktop.Platform.GL.nvidia-595-80 "$FLATPAK_MASKS"
    [ "$status" -ne 0 ]
    grep -qx org.freedesktop.Platform.GL.nvidia-610-57-04 "$FLATPAK_MASKS"
}
