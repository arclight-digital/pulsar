#!/usr/bin/env bash
# steam-grants.sh -- let Flatpak Steam and Faugus run the image's gg, ggm
# and gamescale, so `gg %command%` works in a launch option with nothing set
# up first.
#
# Flatpak reserves /usr for the runtime, so the sandbox never sees the host's
# /usr/bin. host-os:ro shows the host's /usr read-only at /run/host/usr, and
# /usr/lib/pulsar/sandbox-bin holds links to just those three commands, so
# putting that one directory on the sandbox PATH adds nothing else from the
# host. Read-only adds nothing gamescale's own grant does not already give:
# org.freedesktop.Flatpak is how it reaches mutter, and that is a way out of
# the sandbox by design.
#
# THE IMAGE'S COPIES, NOT COPIES IN $HOME. `pulsar setup gamescale` used to
# put gg, ggm and gamescale in ~/.local/bin, and those never update with the
# image. When they were removed on 2026-10-02, every `gg %command%` launch
# died at once: Steam's shell could not find the command.
#
# A SYSTEM OVERRIDE, MERGED, ON EVERY BOOT. Not a file shipped in the image:
# other apps write the same file (Faugus grants Steam its config directory),
# so owning it would erase their grants. `flatpak override --system` adds to
# what is there and only replaces PATH. Every boot, so a new image's grants
# land without a reinstall. It does not need Steam installed, and on a fresh
# install Steam is not yet.
#
# FAUGUS TOO. Its games take a launch-arguments line (`gamescale`, `gg`) the
# same way. Until 2026-10-27 only Steam was granted, so once the home copies
# went, a Faugus game with `gamescale` in it died on "command not found"
# behind a splash that never closed.
#
# DISCORD'S SOCKET TOO. Flatpak Discord listens in
# $XDG_RUNTIME_DIR/app/com.discordapp.Discord, and Windows games reach it
# through the Discord bridge GE-Proton puts in each prefix, which looks there.
# Flathub's Steam already asks for that folder; Faugus does not, so its
# games' Rich Presence went nowhere. Granted to both, so Steam keeps it if
# its manifest drops it.
#
# A user override's PATH beats this one. A home that ran the old installer
# keeps its ~/.local/bin PATH, and its copies, until
# `pulsar setup gamescale --platform steam faugus` moves it over.
#
# DXVK'S DESCRIPTOR HEAP OFF, ON THE NVIDIA IMAGE. DXVK 3.1 binds resources
# through VK_EXT_descriptor_heap where the driver has it, and NVIDIA's (615
# and 620) does. With it, some DirectX 11 games hang the GPU: Xid 109, then
# Xid 31 from GPCCLIENT_GCC reading near address 0. Boltgun did it every run
# from 2026-11-17, Sins of a Solar Empire II on its first in-game frame after
# its 2026-11-16 update, on GE-Proton11-11 and -12 and Proton Experimental
# alike, while the kernel, driver and image stayed the same. Sins II ran
# clean with dxvk.enableDescriptorHeap = False (DXVK falls back to its
# descriptor buffers) on 2026-11-21. Set in DXVK_CONFIG, which GE-Proton adds
# to rather than replaces; a game's launch option that sets DXVK_CONFIG
# itself replaces it, so add this to yours. Not set over a DXVK_CONFIG some
# other admin put here, and taken out again (only if it is still this) on an
# image that doesn't want it: flatpak override's own --unset-env would also
# clear the variable inside the sandbox. Drop it once DXVK or the driver
# fixes the hang.
set -euo pipefail

flatpak=${PULSAR_FLATPAK:-flatpak}
sandbox_bin=/run/host/usr/lib/pulsar/sandbox-bin
overrides=${PULSAR_FLATPAK_OVERRIDES:-/var/lib/flatpak/overrides}
manifest=${PULSAR_MANIFEST:-/usr/share/pulsar/manifest.json}
dxvk_config='dxvk.enableDescriptorHeap = False'

# never fails: a manifest it can't read leaves the PATH grant to go ahead
nvidia=0
[ "$(jq -r '.variant // empty' "$manifest" 2>/dev/null || true)" != nvidia-open ] || nvidia=1

# Each app's own PATH as shipped, plus the one directory; gamescale --doctor
# reports if one goes missing. Faugus's carries the MangoHud, gamescope and
# OBS capture extensions, which its mangohud and gamescope options run from.
steam_path=/app/bin:/app/utils/bin:/usr/bin:${sandbox_bin}
faugus_path=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/MangoHud/bin:/usr/lib/extensions/vulkan/gamescope/bin:/usr/lib/extensions/vulkan/OBSVkCapture/bin:${sandbox_bin}

# DXVK_CONFIG= lines in an app's system override, and whether one is ours
dxvk_line() { grep -s '^DXVK_CONFIG=' "${overrides}/$1" || true; }

grant() {
    local -a dxvk=()
    if [ "$nvidia" = 1 ]; then
        case "$(dxvk_line "$1")" in
            ""|"DXVK_CONFIG=${dxvk_config}") dxvk=(--env=DXVK_CONFIG="$dxvk_config") ;;
        esac
    fi
    # shellcheck disable=SC2088  # flatpak expands ~ per user, at launch
    "$flatpak" override --system \
        --filesystem=host-os:ro \
        --filesystem='~/.local/state/gamescale:create' \
        --filesystem=xdg-run/app/com.discordapp.Discord:create \
        --talk-name=org.freedesktop.Flatpak \
        --env=PATH="$2" \
        "${dxvk[@]}" \
        "$1"
    if [ "$nvidia" = 0 ] && [ "$(dxvk_line "$1")" = "DXVK_CONFIG=${dxvk_config}" ]; then
        local f="${overrides}/$1" tmp
        tmp=$(mktemp "${f}.XXXXXX")
        grep -vxF "DXVK_CONFIG=${dxvk_config}" "$f" > "$tmp" || true
        chmod --reference="$f" "$tmp" && mv "$tmp" "$f"
    fi
}

grant com.valvesoftware.Steam "$steam_path"
grant io.github.Faugus.faugus-launcher "$faugus_path"
