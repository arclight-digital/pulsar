#!/usr/bin/env bash
# gl-nvidia.sh -- install the Flatpak GL extensions that match the NVIDIA
# driver, for the driver that is running AND the one the staged update brings,
# before anything needs them. Run by pulsar-gl-nvidia.service, at boot and
# whenever a deployment is staged (pulsar-gl-nvidia.path).
#
# WHY THIS EXISTS. A Flatpak app does not use the host's NVIDIA userspace. It
# uses org.freedesktop.Platform.GL.nvidia-<version>, an extension whose name
# carries the driver version, and it mounts that extension ONCE, when it
# starts. Every image update moves the driver, and nothing installed the
# matching extension until some later `flatpak update` noticed the new
# version. On cherenkov on 2026-09-26 that update came from GNOME Software 16
# seconds after Steam autostarted at login, so that Steam had no NVIDIA driver
# at all. Its games enumerated only the Intel iGPU and llvmpipe, rendered on
# the iGPU of a laptop whose panel hangs off the NVIDIA GPU, and showed a
# black window. Nothing reported an error.
#
# The staged deployment is the one that matters. The update was staged at
# 11:07 and booted at 11:18, and the next image's driver version is readable
# from its manifest the moment it is staged. That leaves the whole gap
# between staging and reboot to fetch the extension, so it is already
# installed when the new boot's first app starts. The booted driver is here too, for
# the cases that path misses: a reboot straight after staging, an update
# staged while offline, a host that predates this unit.
#
# GL32 goes with GL when any i386 compat runtime is installed. Steam's 32-bit
# half looks for GL32.nvidia-<version> in the same way, and on a Steam
# machine it is the half the client itself runs on.
#
# Deliberately NOT pinned to a branch. Every GL.nvidia-<version> on flathub
# is published on exactly one branch (1.4 today), so the bare id is
# unambiguous and a pin would be a line to forget to move. If flathub ever
# publishes a second branch, the install fails loudly as ambiguous and the
# journal says so.
#
# It also removes the extensions of drivers no deployment carries any more
# (see prune below).
#
# NOTHING UPDATES THEM UNDER A RUNNING APP. Flathub rebuilds an extension
# for the same driver now and then, and an app holds the build it mounted at
# start: replace it and the app keeps the directory name and loses the
# files, and its games are back on the iGPU. On cherenkov on 2026-10-07 GNOME
# Software deployed such a rebuild 34 seconds after Steam, Discord and Faugus
# autostarted, with the driver and its extension both ready ten seconds
# before login. So every installed GL.nvidia-<version> is masked (`flatpak
# mask`): `flatpak update` and GNOME Software skip it, and an extension for a
# NEW driver, which no app holds, still installs. Updating is this script's
# job alone (see refresh below): it fetches the newer build of the running
# driver's extensions and deploys it only when no app on the machine holds
# them, which at boot is before anything has started. Held, it waits for the
# next boot, already downloaded.
#
# Idempotent and quiet: with everything already present it installs nothing. An extension flathub has not published yet (a driver newer
# than its builders) is a normal state, not a failure, because retrying every two minutes
# would not publish it. Anything else that fails -- most often no network
# yet -- exits 1, and Restart=on-failure tries again.
set -euo pipefail

VERSION_FILE=${PULSAR_NVIDIA_VERSION_FILE:-/sys/module/nvidia/version}
SYSROOT=${PULSAR_SYSROOT:-}
# where every user's running Flatpak instances are recorded
RUN_ROOT=${PULSAR_RUN_ROOT:-/run/user}
REMOTE=flathub

log() { echo "gl-nvidia: $*"; }

# Only something version-shaped. The manifest has carried rpm's error text as
# a value before (see check_nvidia in /usr/bin/pulsar), and installing
# "GL.nvidia-package-kmod-..." would retry forever.
version_ok() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)+$ ]]; }

versions=()
add_version() {
    local v=$1 have
    version_ok "$v" || return 0
    for have in ${versions[@]+"${versions[@]}"}; do [ "$have" = "$v" ] && return 0; done
    versions+=("$v")
}

running=""
if [ -r "$VERSION_FILE" ]; then
    running=$(tr -d '[:space:]' < "$VERSION_FILE")
    version_ok "$running" || running=""
    add_version "$running"
fi

# Every deployment's manifest, read straight off disk: staged, booted and
# rollback alike. Not `rpm-ostree status`. The path unit fires the moment
# ostree writes /run/ostree/staged-deployment, and the daemon that answers
# status can still be mid-transaction and not list the new deployment yet.
# That run found only the booted driver, reported everything present and
# exited 0, with nothing left to trigger a retry. The deployment directory is
# written before that marker, so the disk already has the answer. Rollback's
# driver comes along because rolling back is exactly when its extension is
# needed, and it is almost always still installed anyway.
for manifest in "${SYSROOT}"/ostree/deploy/*/deploy/*/usr/share/pulsar/manifest.json; do
    [ -r "$manifest" ] || continue
    add_version "$(jq -r '.nvidia_driver // empty' "$manifest" 2>/dev/null || true)"
done

if [ ${#versions[@]} -eq 0 ]; then
    log "no NVIDIA driver version to match, running or staged; nothing to do"
    exit 0
fi

installed=$(flatpak list --system --runtime --columns=application 2>/dev/null || true)
# Here-strings, not `printf | grep -q`: grep -q exits on its first match, and
# under pipefail a printf still writing the lines after it dies of SIGPIPE,
# which reads as "not installed" (see flatpak-defaults.sh).
has() { grep -Fxq -- "$1" <<<"$installed"; }

# Every installed GL extension for an NVIDIA driver, one id a line.
nvidia_gl() {
    { grep -E '^org\.freedesktop\.Platform\.GL(32)?\.nvidia-[0-9]+(-[0-9]+)+$' <<<"$installed" || true; }
}

# Masked: `flatpak update` and GNOME Software leave it alone (see the
# header). Exact ids, not a pattern: a pattern would also stop an update from
# bringing in a new driver's extension, the one thing it should still do.
masks=$(flatpak mask --system 2>/dev/null | awk '{print $1}' || true)
mask() {
    grep -Fxq -- "$1" <<<"$masks" && return 0
    if flatpak mask --system "$1" >/dev/null 2>&1; then
        masks+=$'\n'"$1"
    else
        log "could not mask $1; an update could replace it under a running app" >&2
    fi
}
unmask() {
    grep -Fxq -- "$1" <<<"$masks" || return 0
    flatpak mask --system --remove "$1" >/dev/null 2>&1 || true
}

# Before anything else, so the window an update could slip into is as short
# as it can be.
while IFS= read -r ref; do
    [ -n "$ref" ] && mask "$ref"
done < <(nvidia_gl)

# The apps running now, any user's, with extension $1 mounted: their short
# names on one line, or a nonzero exit for none. Flatpak's own record of each
# instance names every extension it mounted. An instance directory can
# outlive its app, so only a live pid counts.
holders() {
    local info dir pid name names=" "
    for info in "${RUN_ROOT}"/*/.flatpak/*/info; do
        [ -r "$info" ] || continue
        dir=${info%/info}
        pid=$(cat "${dir}/pid" 2>/dev/null) || continue
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        grep -Eq "^(runtime|app)-extensions=(.*;)?${1//./\\.}=" "$info" || continue
        name=$(sed -n 's/^name=//p' "$info" | head -1)
        case "$names" in *" ${name##*.} "*) ;; *) names+="${name##*.} " ;; esac
    done
    [ "$names" != " " ] || return 1
    names=${names# }
    printf '%s\n' "${names% }"
}

# A newer flathub build of extension $1 (same driver): downloaded now, and
# deployed now only if no running app holds it. --reinstall is how a masked
# ref is updated on purpose; --no-deploy and --no-pull split the slow half
# (the download) from the quick one, so the check for holders sits right
# before the swap. Never a failure: the extension that is there works, and
# the next run tries again.
refresh() {
    local ref=$1 active latest apps
    active=$(flatpak info --system -c "$ref" 2>/dev/null) || return 0
    latest=$(LC_ALL=C flatpak remote-info --system -c "$REMOTE" "$ref" 2>/dev/null) || return 0
    [ -n "$latest" ] && [ "$latest" != "$active" ] || return 0
    if ! LC_ALL=C flatpak install --system --noninteractive --reinstall --no-deploy "$REMOTE" "$ref" >/dev/null 2>&1; then
        log "could not download the newer ${ref}; the next run tries again"
        return 0
    fi
    if apps=$(holders "$ref"); then
        log "newer ${ref} downloaded; ${apps// /, } use the current one, so it goes in at the next boot"
        return 0
    fi
    if LC_ALL=C flatpak install --system --noninteractive --reinstall --no-pull "$REMOTE" "$ref" >/dev/null 2>&1; then
        log "updated ${ref} to flathub's newer build"
    else
        log "could not put in the newer ${ref}; the next run tries again" >&2
    fi
}

# Only the running driver's: the staged one's are fetched fresh when staged,
# and a rebuild of the rollback's would be a download nothing loads.
refresh_running() {
    [ -n "$running" ] || return 0
    local ref
    while IFS= read -r ref; do
        case "$ref" in *".nvidia-${running//./-}") refresh "$ref" ;; esac
    done < <(nvidia_gl)
}

kinds=(GL)
# Compat.i386 is how a 32-bit-capable app (Steam) pulls in the i386 runtime.
# Without one, GL32 is ~100MB nothing can load.
if grep -q '\.Compat\.i386$' <<<"$installed"; then
    kinds+=(GL32)
fi

wanted=()
for v in "${versions[@]}"; do
    for k in "${kinds[@]}"; do
        ref="org.freedesktop.Platform.${k}.nvidia-${v//./-}"
        has "$ref" || wanted+=("$ref")
    done
done

# Extensions for drivers no deployment carries any more. Nothing else ever
# removes them -- `flatpak uninstall --unused` counts them as used, since
# every GL app has the extension point -- and each is ~900MB, so a machine
# that updates nightly piles up one per driver bump. Only once every version
# above is known, and never the running driver, which is in that set. An app
# cannot be holding one of these: after a reboot every app mounts the
# booted driver's.
prune() {
    local keep=" " v ref
    for v in "${versions[@]}"; do keep+="nvidia-${v//./-} "; done
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        case "$keep" in *" ${ref##*.} "*) continue ;; esac
        if flatpak uninstall --system --noninteractive "$ref" >/dev/null 2>&1; then
            unmask "$ref"
            log "removed ${ref}: no deployment runs that driver"
        else
            log "could not remove ${ref}; leaving it" >&2
        fi
    done < <(nvidia_gl)
}

if [ ${#wanted[@]} -eq 0 ]; then
    log "GL extensions present for driver(s): ${versions[*]}"
    refresh_running
    prune
    exit 0
fi

if ! flatpak remotes --system --columns=name 2>/dev/null | grep -Fxq "$REMOTE"; then
    # Not ours to add; `pulsar doctor` reports a missing flathub. Retrying
    # would not make one appear.
    log "no ${REMOTE} remote configured; cannot fetch ${wanted[*]}"
    exit 0
fi

rc=0
for ref in "${wanted[@]}"; do
    # C locale: the "not published" case is recognised by its message, and
    # flatpak translates its messages.
    if out=$(LC_ALL=C flatpak install --system --noninteractive "$REMOTE" "$ref" 2>&1); then
        mask "$ref"
        log "installed ${ref}"
    elif grep -qiE 'nothing matches|no remote refs found' <<<"$out"; then
        log "${ref} is not on ${REMOTE} yet; a later flatpak update will bring it"
    else
        printf '%s\n' "$out" >&2
        log "could not install ${ref}; will retry" >&2
        rc=1
    fi
done
refresh_running
# Only after a clean pass: a run that could not install the new driver's
# extension keeps the old ones, which may be all a rollback has.
[ "$rc" -ne 0 ] || prune
exit "$rc"
