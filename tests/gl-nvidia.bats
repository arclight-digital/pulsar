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
#
# Also pinned: with no driver version known, nothing is removed; a host with
# no NVIDIA module loaded still gets the staged driver's extension; and a run
# that installs something still refreshes and prunes, as a quiet run does.

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
    export FLATPAK_UNPUBLISHED="" FLATPAK_OFFLINE="" FLATPAK_PULL_FAIL=""
    # `flatpak remotes --system --columns=name` on cherenkov, in its order
    export FLATPAK_REMOTES="fedora flathub"
    : > "$FLATPAK_STATE"; : > "$FLATPAK_LOG"
    : > "$FLATPAK_COMMITS"; : > "$FLATPAK_REMOTE"; : > "$FLATPAK_MASKS"

    # Checked against flatpak 1.18.4 (mask in a scratch FLATPAK_USER_DIR, the
    # rest read-only on cherenkov): `mask` lists patterns two spaces in, and
    # nothing at all when there are none; `mask --remove` of an unmasked ref
    # says "No current masked pattern matching" and exits 1; `info -c` and
    # `remote-info -c` print the bare commit; an unpublished extension fails
    # to install with "Nothing matches <ref> in remote flathub", exit 1.
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
    remotes) printf '%s\n' $FLATPAK_REMOTES; exit 0 ;;
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
            [ -n "$FLATPAK_PULL_FAIL" ] && { echo "error: Failed to pull $ref from flathub" >&2; exit 1; }
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

# A running instance of app $1 (pid $2) that mounted extension $3. Real
# instance ids are random; these count up, so the order the script finds
# them in is the order they were made, and a test can pin what it does
# with that order instead of passing on a coin flip.
#
# Laid out as Steam's real one on cherenkov (2026-10-11): "id=commit" pairs
# joined by ";", GL.* among the runtime-extensions, GL32.* among the
# app-extensions (Steam's 32-bit half comes in as app extensions), and a pid
# file with no trailing newline.
instance() {
    INSTANCES=$((${INSTANCES:-0} + 1))
    local dir="${PULSAR_RUN_ROOT}/1000/.flatpak/${INSTANCES}"
    local app_ext="org.freedesktop.Platform.Compat.i386=bbb;org.freedesktop.Platform.GL32.default=ccc"
    local rt_ext="org.freedesktop.Platform.GL.default=aaa"
    case "$3" in
        *.GL32.*) app_ext+=";$3=c0" ;;
        *)        rt_ext+=";$3=c0" ;;
    esac
    mkdir -p "$dir"
    printf '[Application]\nname=%s\nruntime=runtime/org.freedesktop.Platform/x86_64/26.08\n\n[Instance]\ninstance-id=%s\napp-extensions=%s\nruntime-extensions=%s\n' \
        "$1" "$INSTANCES" "$app_ext" "$rt_ext" > "${dir}/info"
    printf '%s' "$2" > "${dir}/pid"
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
    # found Steam first, named in a fixed order
    [[ "$output" == *"Discord, Steam use the current one"* ]]
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

@test "an extension masked and removed in the same run leaves no mask behind" {
    # A host from before the masks: cherenkov's `flatpak mask --system`
    # printed nothing on 2026-10-11. The run masks the stale extension first
    # and removes it after, and the mask it made goes with it.
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-595-80 org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_MASKS"
    [ "$output" = org.freedesktop.Platform.GL.nvidia-610-57-04 ]
}

@test "with no NVIDIA module loaded, the staged driver's extension is still fetched" {
    # No /sys/module/nvidia/version: the module was refused (a BIOS update
    # wiped the MOK list on 2026-09-10) or is not built for this kernel yet.
    rm -f "$PULSAR_NVIDIA_VERSION_FILE"
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_LOG"
    [ "$output" = org.freedesktop.Platform.GL.nvidia-615-71-09 ]
}

@test "with no driver version known at all, no extension is removed" {
    # Nothing to compare against is not "every extension is stale".
    rm -f "$PULSAR_NVIDIA_VERSION_FILE"
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-610-57-04 org.freedesktop.Platform.GL32.nvidia-610-57-04 > "$FLATPAK_STATE"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
    [ ! -s "$FLATPAK_LOG" ]
    [ "$(wc -l < "$FLATPAK_STATE")" -eq 2 ]
}

@test "a newer build that could not be downloaded is not deployed" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    export FLATPAK_PULL_FAIL=1
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FLATPAK_LOG" ]
}

@test "a missing flathub remote is not a failure, since retrying cannot add one" {
    export FLATPAK_REMOTES=fedora
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -s "$FLATPAK_LOG" ]
}

@test "a real install failure puts flatpak's own error in the journal" {
    # The header's promise: if flathub ever publishes a second branch, the
    # install fails as ambiguous "and the journal says so".
    export FLATPAK_OFFLINE=1
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not resolve host: dl.flathub.org"* ]]
}

@test "a run that installs the staged driver's extension still refreshes the running one's" {
    echo org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_LOG"
    [ "$output" = "$(printf '%s\n' org.freedesktop.Platform.GL.nvidia-615-71-09 \
        pull:org.freedesktop.Platform.GL.nvidia-610-57-04 deploy:org.freedesktop.Platform.GL.nvidia-610-57-04)" ]
}

@test "a run that installs the staged driver's extension also removes stale ones" {
    printf '%s\n' org.freedesktop.Platform.GL.nvidia-595-80 org.freedesktop.Platform.GL.nvidia-610-57-04 > "$FLATPAK_STATE"
    stage 615.71.09
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run cat "$FLATPAK_LOG"
    [ "$output" = "$(printf '%s\n' org.freedesktop.Platform.GL.nvidia-615-71-09 -org.freedesktop.Platform.GL.nvidia-595-80)" ]
}

@test "Steam's 32-bit half holds GL32 back too, mounted as an app extension" {
    printf '%s\n' org.freedesktop.Platform.Compat.i386 \
        org.freedesktop.Platform.GL.nvidia-610-57-04 org.freedesktop.Platform.GL32.nvidia-610-57-04 > "$FLATPAK_STATE"
    echo "org.freedesktop.Platform.GL32.nvidia-610-57-04 c1" > "$FLATPAK_REMOTE"
    instance com.valvesoftware.Steam $$ org.freedesktop.Platform.GL32.nvidia-610-57-04
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GL32.nvidia-610-57-04 downloaded; Steam use the current one"* ]]
    run cat "$FLATPAK_LOG"
    [ "$output" = pull:org.freedesktop.Platform.GL32.nvidia-610-57-04 ]
}
