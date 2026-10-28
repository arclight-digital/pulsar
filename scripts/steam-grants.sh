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
# A user override's PATH beats this one. A home that ran the old installer
# keeps its ~/.local/bin PATH, and its copies, until
# `pulsar setup gamescale --platform steam faugus` moves it over.
set -euo pipefail

flatpak=${PULSAR_FLATPAK:-flatpak}
sandbox_bin=/run/host/usr/lib/pulsar/sandbox-bin

# Each app's own PATH as shipped, plus the one directory; gamescale --doctor
# reports if one goes missing. Faugus's carries the MangoHud, gamescope and
# OBS capture extensions, which its mangohud and gamescope options run from.
steam_path=/app/bin:/app/utils/bin:/usr/bin:${sandbox_bin}
faugus_path=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/MangoHud/bin:/usr/lib/extensions/vulkan/gamescope/bin:/usr/lib/extensions/vulkan/OBSVkCapture/bin:${sandbox_bin}

grant() {
    # shellcheck disable=SC2088  # flatpak expands ~ per user, at launch
    "$flatpak" override --system \
        --filesystem=host-os:ro \
        --filesystem='~/.local/state/gamescale:create' \
        --talk-name=org.freedesktop.Flatpak \
        --env=PATH="$2" \
        "$1"
}

grant com.valvesoftware.Steam "$steam_path"
grant io.github.Faugus.faugus-launcher "$faugus_path"
