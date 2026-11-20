# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar setup: the recipes an image can't bake.

# ---------------------------------------------------------------------------
# setup -- the mutable-state recipes an image cannot bake.
# ---------------------------------------------------------------------------
SETUP_HELP='usage: pulsar setup <recipe>

  apps        install the default Flatpaks (root)
  devbox      create the default distrobox, pulsar-dev
  gamemode    add every human account (uid 1000 and up, with a login shell) to the
              gamemode group, for renice (root)
  quadlet     copy the example quadlet to ~/.config/containers/systemd; enable podman auto-update
  gamescale   Steam and Faugus get gg, ggm and gamescale from the image. Run bare, this points an
              older Steam setup at the copies in the image and removes the ones Pulsar put in
              ~/.local/bin. --platform <name>: install for another Flatpak launcher (other
              flags go to the gamescale installer)'

# gg and ggm, the Steam launch options, go beside the gamescale that
# `setup gamescale` just put in ~/.local/bin. A Flatpak launcher's sandbox
# PATH reaches that directory (the installer's grant) and never /usr/bin, so
# without these copies `gg %command%` in Steam is "command not found".
#
# The source is the image's /usr/bin copy, so this never downloads anything
# and never diverges from what native launchers run.
#
# A file already there is the user's unless it is provably ours: byte-identical
# to the image copy, or identical to what this last installed (the recorded
# hash), which is how a fixed gg reaches a home that has the old one. Anything
# else -- someone's own gg, a symlink, an edited copy -- is left exactly as it
# is, and said so. GAMESCALE_BINDIR moves it, as it moves gamescale.
setup_launch_wrappers() {
    local mode=install dry=0 a
    for a in "$@"; do
        case "$a" in
            -h|--help) return 0 ;;
            -u|--uninstall) mode=uninstall ;;
            -n|--dry-run) dry=1 ;;
        esac
    done
    local from=${PULSAR_LAUNCH_WRAPPERS:-/usr/bin}
    local to=${GAMESCALE_BINDIR:-$HOME/.local/bin}
    local rec=${XDG_STATE_HOME:-$HOME/.local/state}/pulsar/launch-wrappers
    local w dst ours have installed=0
    for w in gg ggm; do
        dst="${to}/${w}"
        if [ ! -r "${from}/${w}" ]; then
            printf '%s is not in this image (%s); skipping it\n' "$w" "${from}/${w}"
            continue
        fi
        ours=0
        if [ -f "$dst" ] && [ ! -L "$dst" ]; then
            if cmp -s "${from}/${w}" "$dst"; then
                ours=1
            elif [ -r "${rec}/${w}.sha256" ]; then
                have=$(sha256sum < "$dst" | cut -d' ' -f1)
                [ "$have" = "$(cat "${rec}/${w}.sha256")" ] && ours=1
            fi
        fi

        if [ "$mode" = uninstall ]; then
            if [ "$ours" = 1 ]; then
                if [ "$dry" = 1 ]; then
                    printf 'would remove %s\n' "$dst"
                else
                    rm -f "$dst" "${rec}/${w}.sha256"
                    printf 'removed %s\n' "$dst"
                fi
            elif [ -e "$dst" ] || [ -L "$dst" ]; then
                printf 'left %s: it is not the copy Pulsar installed\n' "$dst"
            fi
            continue
        fi

        if [ -e "$dst" ] || [ -L "$dst" ]; then
            if [ "$ours" = 1 ] && cmp -s "${from}/${w}" "$dst"; then
                # identical is indistinguishable from ours, so adopt it:
                # the next image's gg can then replace it
                if [ "$dry" = 0 ] && [ ! -e "${rec}/${w}.sha256" ]; then
                    mkdir -p "$rec"
                    sha256sum < "$dst" | cut -d' ' -f1 > "${rec}/${w}.sha256"
                fi
                printf '%s is current\n' "$dst"
                installed=1
                continue
            fi
            if [ "$ours" = 0 ]; then
                printf 'left %s alone: it is your own and differs from %s\n' "$dst" "${from}/${w}"
                continue
            fi
        fi
        if [ "$dry" = 1 ]; then
            printf 'would install %s\n' "$dst"
            continue
        fi
        mkdir -p "$to" "$rec"
        install -m 0755 "${from}/${w}" "$dst"
        sha256sum < "$dst" | cut -d' ' -f1 > "${rec}/${w}.sha256"
        printf 'installed %s\n' "$dst"
        installed=1
    done
    if [ "$mode" = install ] && [ "$dry" = 0 ] && [ "$installed" = 1 ]; then
        printf 'Steam launch options:  gg %%command%%   (ggm %%command%% adds the MangoHud overlay)\n'
    fi
}

# The sandbox PATHs pulsar-steam-grants.service sets. Kept equal to
# scripts/steam-grants.sh; tests/gg.bats checks they agree.
STEAM_SANDBOX_PATH=/app/bin:/app/utils/bin:/usr/bin:/run/host/usr/lib/pulsar/sandbox-bin
FAUGUS_SANDBOX_PATH=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/MangoHud/bin:/usr/lib/extensions/vulkan/gamescope/bin:/usr/lib/extensions/vulkan/OBSVkCapture/bin:/run/host/usr/lib/pulsar/sandbox-bin

# Flatpak Steam and Faugus run the image's gg, ggm and gamescale
# (steam-grants.sh says how), so for them there is nothing to install. What
# is left is a home the old recipe set up: its user override's PATH ends in
# ~/.local/bin and beats the image's, so the app keeps running the copies
# there, which never update. This points that PATH at the image's copies and
# removes the copies Pulsar can prove it made, unless something still runs
# them. Anything else in ~/.local/bin is left, and named.
#
# Whether a Flatpak app is running: a live pid in one of its instance
# directories (those of an app that exited can linger).
flatpak_app_running() {
    local app=$1 d pid
    for d in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/.flatpak/*/; do
        grep -qx "name=${app}" "${d}info" 2>/dev/null || continue
        pid=$(cat "${d}pid" 2>/dev/null) || continue
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

# Whether a user override's PATH includes the directory.
override_path_has() {
    local p
    p=$(sed -n 's/^PATH=//p' "$1" 2>/dev/null) || return 1
    case ":${p}:" in *":${2}:"*) return 0 ;; esac
    return 1
}

# setup_builtin DRY KEEP_HOME NAME... -- NAME is steam or faugus
setup_builtin() {
    local dry=$1 keep_home=$2
    shift 2
    local ovdir=${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/overrides
    local bindir=${GAMESCALE_BINDIR:-$HOME/.local/bin}
    local gs_src=${PULSAR_GAMESCALE_SYSTEM:-/usr/bin/gamescale}
    local name app path label quit ov f
    local moved=" " running=0 stuck=()
    for name in "$@"; do
        case "$name" in
            steam) app=com.valvesoftware.Steam path=$STEAM_SANDBOX_PATH label=Steam
                   quit='Quit Steam (Steam menu > Exit)' ;;
            faugus) app=io.github.Faugus.faugus-launcher path=$FAUGUS_SANDBOX_PATH label=Faugus
                    quit='Quit Faugus and any game it started' ;;
        esac
        printf '%s: gg, ggm and gamescale come with the image; nothing to install\n' "$label"
        ov=${ovdir}/${app}
        if [ -r "$ov" ] && grep -q '^PATH=' "$ov" && ! grep -qx "PATH=${path}" "$ov"; then
            if [ "$dry" = 1 ]; then
                printf 'would point the PATH in your %s override at the image copies\n' "$label"
            else
                need flatpak
                flatpak override --user --env=PATH="${path}" "$app"
                printf 'pointed the PATH in your %s override at the image copies\n' "$label"
            fi
            moved+="${app} "
        fi
        # A running app read its PATH when it started, and still finds gg in
        # ~/.local/bin: taking the copies away now would make every launch
        # exit at once ("gg: command not found") until it restarts.
        if [ "$keep_home" = 0 ] && [ "$dry" = 0 ] && flatpak_app_running "$app"; then
            printf '%s is open and still uses the copies in %s. %s and open it again;\n' "$label" "$bindir" "$quit"
            printf 'it uses the image copies from then on. Run pulsar setup gamescale again afterwards to remove the old copies.\n'
            running=1
        fi
    done
    # Another launcher granted in the same run needs the home copies.
    if [ "$keep_home" = 0 ] && [ "$running" = 0 ]; then
        # So does any app whose override this run did not move off them:
        # removing the copies under it is how Faugus lost gamescale.
        for f in "$ovdir"/*; do
            [ -f "$f" ] || continue
            case "$moved" in *" ${f##*/} "*) continue ;; esac
            override_path_has "$f" "$bindir" && stuck+=("${f##*/}")
        done
        if [ ${#stuck[@]} -gt 0 ]; then
            printf 'left the copies in %s: %s still runs them from there\n' "$bindir" "${stuck[*]}"
        else
            if [ "$dry" = 1 ]; then
                setup_launch_wrappers --uninstall --dry-run
            else
                setup_launch_wrappers --uninstall
            fi
            local dst="${bindir}/gamescale"
            if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$gs_src" "$dst"; then
                if [ "$dry" = 1 ]; then
                    printf 'would remove %s\n' "$dst"
                else
                    rm -f "$dst"
                    printf 'removed %s\n' "$dst"
                fi
            elif [ -e "$dst" ] || [ -L "$dst" ]; then
                printf 'left %s: it differs from the image copy; remove it if Pulsar put it there\n' "$dst"
            fi
        fi
    fi
    for name in "$@"; do
        case "$name" in
            steam) printf 'Steam launch options:  gg %%command%%   (ggm %%command%% adds the MangoHud overlay)\n' ;;
            faugus) printf 'Faugus launch arguments:  gg   (ggm adds the MangoHud overlay)\n' ;;
        esac
    done
}

cmd_setup() {
    local recipe=${1:-}
    shift || true
    no_json setup
    case "$recipe" in
        ""|-h|--help|help) printf '%s\n' "$SETUP_HELP"; return 0 ;;
        # gamescale hands its arguments to upstream's installer, --help too
        gamescale) ;;
        *)
            case "${1:-}" in
                -h|--help)
                    printf '%s\n' "$SETUP_HELP" | awk -v r="$recipe" '$1 == r { sub(/^ +/, ""); print "pulsar setup " $0; f = 1 } END { exit !f }' \
                        || die "unknown recipe: ${recipe} (see: pulsar setup --help)"
                    return 0 ;;
            esac
            [ $# -eq 0 ] || die "'setup ${recipe}' takes no arguments (got: $*)" ;;
    esac
    case "$recipe" in
    devbox)
        need_user "setup devbox"
        need distrobox
        local ini=/usr/share/pulsar/distrobox.ini
        [ -r "$ini" ] || die "no distrobox manifest at ${ini}"
        distrobox assemble create --file "$ini"
        ;;
    quadlet)
        need_user "setup quadlet"
        local tpl=/usr/share/pulsar/templates/example.container
        local dir="${HOME}/.config/containers/systemd"
        [ -r "$tpl" ] || die "no quadlet template at ${tpl}"
        mkdir -p "$dir"
        if [ -e "${dir}/example.container" ]; then
            printf 'example.container already exists; leaving it alone\n'
        else
            cp "$tpl" "${dir}/example.container"
            printf 'copied template to %s/example.container\n' "$dir"
        fi
        systemctl --user daemon-reload
        systemctl --user enable --now podman-auto-update.timer
        printf 'edit it, then: systemctl --user start example\n'
        ;;
    apps)
        # The one recipe that is root, not user: the defaults install
        # system-wide, same as the first-boot service. Both run the same
        # script, so this is also the manual retry path if that service is
        # sitting in its offline retry loop and you would rather watch.
        need_root "setup apps"
        need flatpak
        local script=/usr/libexec/pulsar/flatpak-defaults.sh
        [ -x "$script" ] || die "flatpak-defaults is not staged in this image (${script})"
        exec "$script"
        ;;
    gamemode)
        # Root, like `setup apps`, and for the same reason: this writes
        # /etc/group, not $HOME. It runs the same script as the first-boot
        # service, so it is also the manual path when that service is sitting
        # in its retry loop waiting for an account to exist.
        #
        # Idempotent: accounts already in the group are left alone, so this is
        # the right command after adding a second user too.
        need_root "setup gamemode"
        local script=/usr/libexec/pulsar/gamemode-group.sh
        [ -x "$script" ] || die "gamemode-group is not staged in this image (${script})"
        exec "$script"
        ;;
    gamescale)
        need_user "setup gamescale"
        # Delegates to upstream's installer against the copy staged in the
        # image, so this runs offline from pinned, hash-verified files and the
        # ~/.local copy matches the image exactly. Reimplementing the flatpak
        # grants here would drift from upstream the moment they change one.
        local src=${PULSAR_GAMESCALE_INSTALLER:-/usr/share/pulsar/gamescale/install.sh}
        [ -x "$src" ] || die "gamescale is not staged in this image (${src})"
        # Steam and Faugus come out of the platform list (the image grants
        # them) and the rest goes to the installer. --help, --uninstall and
        # `all` pass through untouched: they are upstream's to interpret.
        local a in_plat=0 saw_plat=0 dry=0 raw=0
        local -a pass=() plats=() rest=() builtin=()
        for a in "$@"; do
            case "$a" in
                -h|--help|-u|--uninstall) raw=1 ;;
                -n|--dry-run) dry=1 ;;
            esac
            if [ "$a" = --platform ]; then
                in_plat=1; saw_plat=1; continue
            fi
            if [ "$in_plat" = 1 ] && [ "${a#-}" = "$a" ]; then
                plats+=("$a"); continue
            fi
            in_plat=0; pass+=("$a")
        done
        [ "$saw_plat" = 1 ] || plats=(steam)
        for a in ${plats[@]+"${plats[@]}"}; do
            case "$a" in
                steam|com.valvesoftware.Steam) builtin+=(steam) ;;
                faugus|io.github.Faugus.faugus-launcher) builtin+=(faugus) ;;
                all) raw=1 ;;
                *) rest+=("$a") ;;
            esac
        done
        if [ "$raw" = 1 ]; then
            printf 'running the staged gamescale installer (offline, pinned)\n'
            "$src" "$@"
            setup_launch_wrappers "$@"
            return
        fi
        if [ ${#rest[@]} -gt 0 ]; then
            printf 'running the staged gamescale installer (offline, pinned)\n'
            # set -e: a failed install stops here, before gg lands beside nothing
            "$src" ${pass[@]+"${pass[@]}"} --platform "${rest[@]}"
            setup_launch_wrappers ${pass[@]+"${pass[@]}"}
        fi
        if [ ${#builtin[@]} -gt 0 ]; then
            setup_builtin "$dry" "$(( ${#rest[@]} > 0 ))" "${builtin[@]}"
        fi
        ;;
    *) die "unknown recipe: ${recipe} (see: pulsar setup --help)" ;;
    esac
}
