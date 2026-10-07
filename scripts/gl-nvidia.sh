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
# Idempotent and quiet: with everything already present it installs nothing. An extension flathub has not published yet (a driver newer
# than its builders) is a normal state, not a failure, because retrying every two minutes
# would not publish it. Anything else that fails -- most often no network
# yet -- exits 1, and Restart=on-failure tries again.
set -euo pipefail

VERSION_FILE=${PULSAR_NVIDIA_VERSION_FILE:-/sys/module/nvidia/version}
SYSROOT=${PULSAR_SYSROOT:-}
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

if [ -r "$VERSION_FILE" ]; then
    add_version "$(tr -d '[:space:]' < "$VERSION_FILE")"
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
    printf '%s\n' "$installed" \
        | { grep -E '^org\.freedesktop\.Platform\.GL(32)?\.nvidia-[0-9]+(-[0-9]+)+$' || true; } \
        | while IFS= read -r ref; do
              case "$keep" in *" ${ref##*.} "*) continue ;; esac
              if flatpak uninstall --system --noninteractive "$ref" >/dev/null 2>&1; then
                  log "removed ${ref}: no deployment runs that driver"
              else
                  log "could not remove ${ref}; leaving it" >&2
              fi
          done
}

if [ ${#wanted[@]} -eq 0 ]; then
    log "GL extensions present for driver(s): ${versions[*]}"
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
        log "installed ${ref}"
    elif grep -qiE 'nothing matches|no remote refs found' <<<"$out"; then
        log "${ref} is not on ${REMOTE} yet; a later flatpak update will bring it"
    else
        printf '%s\n' "$out" >&2
        log "could not install ${ref}; will retry" >&2
        rc=1
    fi
done
# Only after a clean pass: a run that could not install the new driver's
# extension keeps the old ones, which may be all a rollback has.
[ "$rc" -ne 0 ] || prune
exit "$rc"
