# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar doctor: the health checks.

# ---------------------------------------------------------------------------
# doctor -- the reason this CLI exists.
#
# Checks carry a severity, and only `fail` changes the exit code. The
# distinction matters and is the same one greenboot's required.d/wanted.d
# split encodes: a scheduler that did not attach is a performance regression
# on a completely usable machine, so it warns. A boot that greenboot marked
# red is a system that tried to roll itself back, so it fails.
# ---------------------------------------------------------------------------
CHECK_JSON=""
RC=0
RECORDED=0

# record <id> <ok|warn|fail> <headline> [detail]
record() {
    local id=$1 status=$2 head=$3 detail=${4:-}
    local color symbol
    RECORDED=$((RECORDED + 1))
    case "$status" in
        ok)   color=$C_OK;   symbol="ok  " ;;
        warn) color=$C_WARN; symbol="warn" ;;
        fail) color=$C_FAIL; symbol="FAIL"; RC=1 ;;
        # a typo'd severity would otherwise die on an unbound variable three
        # lines down, attributed to nothing
        *)    die "internal error: record() called with status '${status}'" ;;
    esac
    if [ "${JSON:-0}" = 1 ]; then
        CHECK_JSON+=$(jq -n -c --arg i "$id" --arg s "$status" --arg h "$head" --arg d "$detail" \
            '{id:$i, status:$s, summary:$h, detail:$d}'),
    else
        printf '%s%s%s  %-14s %s\n' "$color" "$symbol" "$C_RESET" "$id" "$head"
        [ -n "$detail" ] && printf '                     %s%s%s\n' "$C_DIM" "$detail" "$C_RESET"
    fi
    return 0
}

check_scheduler() {
    # EEVDF, the kernel's own scheduler, is Pulsar's default since 2026-11-03;
    # scx.service is an opt-in. Only an opt-in that did not attach warns.
    local state sx=${PULSAR_SCHED_EXT:-/sys/kernel/sched_ext}
    local supported=${PULSAR_SCX_SUPPORTED:-/usr/lib/pulsar/scx-supported}
    if [ ! -e "$sx/state" ]; then
        record scheduler ok "EEVDF (kernel has no sched_ext)" ; return
    fi
    state=$(cat "$sx/state" 2>/dev/null || echo unknown)
    local enabled
    # is-enabled PRINTS "disabled" and THEN exits nonzero; see is-active below
    enabled=$(systemctl is-enabled scx.service 2>/dev/null) || true
    if [ "$state" = "enabled" ]; then
        local ops; ops=$(cat "$sx/root/ops" 2>/dev/null || echo unknown)
        record scheduler ok "sched_ext scheduler attached (opt-in)" "root scheduler: ${ops}"
    elif [ "$enabled" != "enabled" ]; then
        record scheduler ok "EEVDF, Pulsar's default" \
               "a sched_ext scheduler is opt-in: sudo systemctl enable --now scx.service"
    elif [ ! -e "$supported" ]; then
        # Not a fault: this kernel's BTF cannot load ANY BPF scheduler, the
        # build detected that, and scx.service is skipped rather than failed.
        # Reporting it as a warning forever would be indistinguishable from
        # something the user could fix, and there is nothing to fix here.
        record scheduler ok "EEVDF: scx.service is enabled, but this kernel cannot load a BPF scheduler"
    else
        # Warn, not fail. The machine runs fine on EEVDF -- but this is the
        # check that catches the failure `systemctl is-active scx.service`
        # cannot see, where the unit is green and no scheduler ever attached.
        local unit
        # NOT $(cmd || echo fallback): is-active PRINTS "failed" and THEN exits
        # nonzero, so the fallback appends to it and you get "failed\nunknown".
        unit=$(systemctl is-active scx.service 2>/dev/null) || true
        [ -n "$unit" ] || unit=unknown
        # scx.service binds the kernel config into its own /boot, so the
        # missing-/boot/config cause this used to name cannot happen to it any
        # more. What the unit last said is the most useful next clue.
        local last
        last=$(journalctl -u scx.service -b -n 1 -o cat --no-pager 2>/dev/null | head -c 200) || true
        [ -z "$last" ] || unit="${unit}; last: ${last}"
        record scheduler warn "scx.service is enabled but sched_ext is '${state}', so EEVDF is running" \
               "scx.service: ${unit}"
    fi
}

check_ntsync() {
    if [ -e /dev/ntsync ]; then
        record ntsync ok "/dev/ntsync present" "$(stat -c '%A %U:%G' /dev/ntsync 2>/dev/null || true)"
    elif grep -q '^ntsync ' /proc/modules 2>/dev/null; then
        record ntsync warn "ntsync module loaded but /dev/ntsync is missing" "check 70-ntsync.rules"
    else
        record ntsync warn "ntsync not available" "games still run, through Proton's slower fallback (fsync)"
    fi
}

# gamemode_conf <key> <int|float>: the [general] value gamemoded runs with,
# as "value<TAB>file", or nothing when no file sets it. gamemoded reads
# gamemode.ini from /usr/share/gamemode, /etc, $XDG_CONFIG_HOME (else
# ~/.config) and its working directory, in that order, and a later file's
# value replaces an earlier one's (load_config_files in gamemode-config.c,
# 1.8.2). It runs as a systemd user service with no WorkingDirectory, so that
# last directory is the home directory. Parsed the way its inih does: ; and #
# start a comment line, a ; after whitespace ends a value, spaces around the
# name and the value do not count. A value gamemode would reject (not a whole
# number for renice, not a number for a float) leaves the earlier one.
gamemode_conf() {
    local key=$1 type=$2 home cfg f
    if [ -n "${SUDO_USER:-}" ]; then
        home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
        cfg=${home:+${home}/.config}
    else
        home=${HOME:-}
        cfg=${XDG_CONFIG_HOME:-${home:+${home}/.config}}
    fi
    local -a files=() readable=()
    files=("${PULSAR_GAMEMODE_DEFAULT_INI:-/usr/share/gamemode/gamemode.ini}" "${PULSAR_GAMEMODE_INI:-/etc/gamemode.ini}")
    [ -z "$cfg" ] || files+=("${cfg}/gamemode.ini")
    [ -z "$home" ] || files+=("${home}/gamemode.ini")
    for f in "${files[@]}"; do [ -r "$f" ] && readable+=("$f"); done
    [ ${#readable[@]} -gt 0 ] || return 0
    awk -v key="$key" -v type="$type" '
        FNR == 1 { sec = "" }
        { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, "") }
        /^[;#]/ || $0 == "" { next }
        /^\[/ { sec = $0; sub(/^\[/, "", sec); sub(/\].*$/, "", sec); next }
        sec == "general" {
            i = index($0, "="); j = index($0, ":")
            if (!i || (j && j < i)) i = j
            if (!i) next
            name = substr($0, 1, i - 1); sub(/[ \t]+$/, "", name)
            if (name != key) next
            v = substr($0, i + 1); sub(/^[ \t]+/, "", v)
            sub(/[ \t];.*$/, "", v); sub(/[ \t]+$/, "", v)
            if (type == "int" && v !~ /^[+-]?[0-9]+$/) next
            if (type == "float" && v !~ /^[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?$/) next
            val = v; src = FILENAME
        }
        END { if (src != "") printf "%s\t%s\n", val, src }' "${readable[@]}" 2>/dev/null || true
}

check_gamemode() {
    # Paths are overridable for the same reason the rest of the CLI's are:
    # these branches are decisions worth testing, not plumbing worth mocking.
    local ini=${PULSAR_GAMEMODE_INI:-/etc/gamemode.ini} group=gamemode
    local limits_dir=${PULSAR_LIMITS_DIR:-/etc/security/limits.d}
    local limits_conf=${PULSAR_LIMITS_CONF:-/etc/security/limits.conf}

    # Degrade honestly off a Pulsar system: no gamemode, nothing to say.
    if [ ! -f "$ini" ] && ! command -v gamemoded >/dev/null 2>&1; then
        record gamemode ok "gamemode not installed"; return
    fi

    # If renice is not being asked for, membership is irrelevant and a warning
    # about it would be noise. What counts is the value gamemoded ends up
    # with, which a user's own gamemode.ini can change.
    local renice src
    IFS=$'\t' read -r renice src <<<"$(gamemode_conf renice int)"
    renice=${renice#+}
    if [ -z "$renice" ] || [ "$renice" -eq 0 ] 2>/dev/null; then
        record gamemode ok "gamemode present; renice not requested${src:+ (renice=${renice} in ${src})}"; return
    fi
    # config_get_renice_value: anything outside 1 to 20 is dropped
    if [ "$renice" -lt 1 ] || [ "$renice" -gt 20 ]; then
        record gamemode warn "renice=${renice} in ${src} is outside 1 to 20, so gamemode ignores it"
        return
    fi

    if ! getent group "$group" >/dev/null 2>&1; then
        record gamemode warn "no '${group}' group, so renice=${renice} is inert" \
               "the gamemode package normally creates it"
        return
    fi

    # The grant is what makes the priority possible; without it, membership
    # buys nothing and the symptom is silence.
    if ! grep -rqs -- "@${group}" "$limits_dir" "$limits_conf"; then
        record gamemode warn "no '@${group}' nice grant, so renice=${renice} is inert" \
               "expected /etc/security/limits.d/10-gamemode.conf"
        return
    fi

    # Under sudo the interesting account is the human one, not root: root is
    # never in the group and never needs to be.
    local user=${SUDO_USER:-}
    [ -n "$user" ] || user=$(id -un)

    if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
        record gamemode warn "${user} is not in the ${group} group; renice=${renice} does nothing" \
               "sudo pulsar setup gamemode, then log out and back in"
        return
    fi

    # Enrolled in /etc/group is not the same as live in THIS session:
    # supplementary groups are fixed by PAM at login, so the session that ran
    # the enrolment still does not have it. That gap is the whole reason this
    # check reports two states instead of one.
    if [ -z "${SUDO_USER:-}" ] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
        record gamemode warn "${user} is enrolled in ${group}, but this session predates it" \
               "log out and back in; renice=${renice} applies from the next login"
        return
    fi

    # the iGPU threshold: Pulsar's /etc/gamemode.ini sets -1 (off) for hybrid
    # laptops; say what gamemoded will actually use
    local igpu igpu_src
    IFS=$'\t' read -r igpu igpu_src <<<"$(gamemode_conf igpu_power_threshold float)"
    local igpu_detail
    if [ -z "$igpu" ]; then
        igpu_detail="iGPU governor switch on (igpu_power_threshold=0.3, gamemode's default)"
    elif awk -v t="$igpu" 'BEGIN { exit !(t + 0 < 0) }'; then
        igpu_detail="iGPU governor switch off (igpu_power_threshold=${igpu} in ${igpu_src})"
    else
        igpu_detail="iGPU governor switch on (igpu_power_threshold=${igpu} in ${igpu_src})"
    fi
    record gamemode ok "${user} is in ${group}; renice=${renice} available" "$igpu_detail"
}

check_mangohud() {
    local list=${PULSAR_FLATPAKS_LIST:-/usr/share/pulsar/flatpaks.list}
    local id=org.freedesktop.Platform.VulkanLayer.MangoHud
    local launcher=com.valvesoftware.Steam

    # Degrade honestly off a Pulsar system.
    if [ ! -r "$list" ] || ! command -v flatpak >/dev/null 2>&1; then
        record mangohud ok "no flatpak defaults here"; return
    fi

    # The branch the image pins. No entry means nothing to keep in step.
    local pinned
    pinned=$(sed -e 's/#.*//' "$list" \
             | awk -v i="$id" '$1 ~ "^"i"//" { sub(/.*\/\//, "", $1); print $1; exit }') || true
    if [ -z "$pinned" ]; then
        record mangohud ok "the MangoHud layer is not in the defaults"; return
    fi

    # --columns rather than `flatpak info`, whose labels are translated.
    local installed
    installed=$(flatpak list --columns=application,branch 2>/dev/null \
                | awk -v i="$id" '$1 == i { print $2 }' | paste -sd, -) || true

    if [ -z "$installed" ]; then
        record mangohud warn "MangoHud layer not installed; Flatpak games get no overlay" \
               "sudo flatpak install flathub ${id}//${pinned}"
        return
    fi

    # What the shipped launcher actually runs on. Without it there is nothing
    # to be out of step WITH, so the pin is simply reported.
    local used
    used=$(flatpak list --app --columns=application,runtime 2>/dev/null \
           | awk -v a="$launcher" '$1 == a { n = split($2, p, "/"); print p[n]; exit }') || true
    if [ -z "$used" ]; then
        record mangohud ok "MangoHud layer present (${installed}); no Steam to check against"
        return
    fi

    # THE ROT THIS CHECK EXISTS FOR. An extension is only visible to apps on
    # the matching runtime, so when the launcher moves branch and the pin does
    # not, the overlay stops appearing and nothing anywhere logs a reason.
    if ! grep -q ",${used}," <<<",${installed},"; then
        record mangohud warn "MangoHud layer is ${installed}, but Steam runs on ${used}" \
               "the overlay is invisible to Flatpak games; repin flatpaks.list to //${used}"
        return
    fi

    if [ "$pinned" != "$used" ]; then
        record mangohud warn "flatpaks.list pins //${pinned}, Steam runs on ${used}" \
               "installed (${installed}) still covers it; repin before the old branch goes"
        return
    fi

    record mangohud ok "MangoHud layer ${used} matches Steam's runtime"
}

check_greenboot() {
    local enabled
    # is-enabled prints "not-found" AND exits nonzero. Appending a fallback
    # produced "not-found\nnot-found", which matched nothing, so this check
    # fell through and reported "passed" on a system with no greenboot at all.
    enabled=$(systemctl is-enabled greenboot-healthcheck.service 2>/dev/null) || true
    [ -n "$enabled" ] || enabled=not-found
    if [ "$enabled" = "not-found" ] || [ "$enabled" = "masked" ]; then
        record greenboot warn "greenboot is not installed on this deployment" \
               "a boot that fails its health checks will not be rolled back"
        return
    fi
    if [ "$enabled" = "disabled" ]; then
        record greenboot warn "greenboot is installed but disabled" \
               "a boot that fails its health checks will not be rolled back: sudo systemctl enable greenboot-healthcheck.service"
        return
    fi
    # Result=success is also what a unit that has NEVER RUN reports, so on
    # its own it read a greenboot that had not run (or was still running,
    # early in boot) as a green boot. The unit is RemainAfterExit, so after a
    # real pass it sits active/exited.
    local result active
    result=$(systemctl show -p Result --value greenboot-healthcheck.service 2>/dev/null) || result=unknown
    active=$(systemctl show -p ActiveState --value greenboot-healthcheck.service 2>/dev/null) || active=unknown
    if [ "$result" = "success" ] && [ "$active" != "active" ]; then
        record greenboot warn "health checks have not finished this boot (${active:-unknown})" \
               "journalctl -u greenboot-healthcheck.service"
    elif [ "$result" = "success" ] || [ "$result" = "" ]; then
        record greenboot ok "health checks passed" "boot marked green"
    else
        # A red boot means greenboot is counting down to a rollback.
        record greenboot fail "last health check result: ${result}" \
               "journalctl -u greenboot-healthcheck.service"
    fi
}

# Is there an NVIDIA display device (vendor 0x10de, PCI class 0x03xxxx) on
# the bus? Read from sysfs, which needs no tools. "Cannot tell" -- no sysfs,
# as in a container -- answers yes, so doctor falls back to the stricter
# reading rather than excusing a missing module on a guess.
# PULSAR_SYS_PCI: the tests' fixture.
nvidia_gpu_present() {
    local bus="${PULSAR_SYS_PCI:-/sys/bus/pci/devices}" d
    [ -d "$bus" ] || return 0
    for d in "$bus"/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
        case "$(cat "$d/class" 2>/dev/null)" in 0x03*) return 0 ;; esac
    done
    return 1
}

check_nvidia() {
    local variant; variant=$(mf variant)
    case "$variant" in
        *nvidia*) ;;
        "") # No manifest. Only report if the driver is actually present.
            grep -q '^nvidia ' "${PULSAR_PROC_MODULES:-/proc/modules}" 2>/dev/null || return 0 ;;
        *)  # Vanilla image: nvidia absence is correct, say nothing.
            return 0 ;;
    esac
    # /proc/modules and /sys, never lsmod/modinfo: those live in /usr/sbin,
    # which is not on every user's PATH, and under pipefail a missing binary
    # reads as "no nvidia module" -- a false clean bill of health.
    # PULSAR_PROC_MODULES: the tests' fixture; rootless podman shows the
    # HOST's /proc/modules, so without it a GPU-less build host fails here
    # while a developer's nvidia laptop passes.
    if ! grep -q '^nvidia ' "${PULSAR_PROC_MODULES:-/proc/modules}" 2>/dev/null; then
        # No module on a machine with no NVIDIA GPU is not a rejected
        # module, it is the wrong image -- and it is also every VM this image
        # is boot-tested on. Only a GPU that is there and unserved is a fail.
        if ! nvidia_gpu_present; then
            record nvidia warn "NVIDIA image, but this machine has no NVIDIA GPU" \
                   "the vanilla image fits it: sudo bootc switch ghcr.io/arclight-digital/pulsar:latest"
            return
        fi
        record nvidia fail "NVIDIA image, but no nvidia module is loaded" \
               "with Secure Boot on, the module loads only after Pulsar's key is enrolled: mokutil --test-key /etc/pki/pulsar/MOK.der (the README has the steps)"
        return
    fi
    local running expected
    running=$(cat /sys/module/nvidia/version 2>/dev/null) || true
    [ -n "$running" ] || running=unknown
    expected=$(mf nvidia_driver)
    # Only compare against something version-shaped. A manifest once carried
    # nvidia_driver="package kmod-nvidia-open is not installed" -- rpm prints
    # that on stdout and exits 1, so a `$(rpm -q ... || fallback)` captured it
    # as the value, and comparing against it warned on every run, forever.
    # Garbage in the manifest is the manifest's bug to report, not a reason
    # to cry wolf about a driver that is fine.
    case "$expected" in
        *[!0-9.]*|'') expected="" ;;
    esac
    if [ -n "$expected" ] && [ "$running" != "$expected" ]; then
        record nvidia warn "driver ${running}, image expects ${expected}" \
               "restart into the current image; if it persists, run: pulsar report"
    else
        record nvidia ok "nvidia-open ${running} loaded"
    fi
}

# Flatpak apps do not see the host's NVIDIA userspace. Each one mounts
# org.freedesktop.Platform.GL.nvidia-<driver version> once, when it starts,
# and keeps whatever it got until it exits. Two ways that goes wrong were
# both seen on cherenkov on 2026-09-26, and neither reports an error:
#
#   - the app started before the matching extension was installed (Steam
#     autostarted at login; GNOME Software installed the extension 16s
#     later), so its sandbox has no NVIDIA driver at all;
#   - the extension was redeployed under a running app, which kept the
#     directory name and lost the files: every game launch after that logged
#     "nvidia_icd.json: No such file or directory".
#
# Either way the app's games enumerate only the iGPU and llvmpipe. On a laptop
# whose panel hangs off the NVIDIA GPU that is a black window, and the only
# fix is to quit the app and start it again.
#
# The evidence is flatpak's own record of each running instance,
# $XDG_RUNTIME_DIR/.flatpak/<instance>/info, which names every extension the
# instance mounted and the COMMIT it mounted. An instance is healthy when it
# has GL.nvidia-<running driver> and that commit is still deployed. It is
# stale when the extension is absent, or when the commit it holds has since
# been replaced and deleted. Multiarch apps (Steam) are held to the same test
# for GL32. Not a look inside /proc/<pid>/root: Steam's pressure-vessel
# sub-sandboxes carry empty GL skeletons there and get the driver another way,
# so the look reads a healthy Steam as broken.
#
# Sets FGL_STATUS (skip|missing|stale|ok), FGL_DRIVER and FGL_APPS/FGL_IDS
# (the stale apps' short names and instance ids).
flatpak_gl_scan() {
    FGL_STATUS=skip; FGL_DRIVER=""; FGL_APPS=""; FGL_IDS=""
    have flatpak || return 0
    # Instances are per user and sudo drops XDG_RUNTIME_DIR, so as root this
    # would look at root's (empty) set and call it healthy. Say nothing.
    # (The tests point PULSAR_FLATPAK_RUN at a fixture and may run as root on
    # the build host; that is not a sudo'd user, so the guard does not apply.)
    [ "$(id -u)" -ne 0 ] || [ -n "${PULSAR_FLATPAK_RUN:-}" ] || return 0
    local variant; variant=$(mf variant)
    case "$variant" in
        *nvidia*|"") ;;
        *) return 0 ;;
    esac
    local ver
    ver=$(tr -d '[:space:]' < "${PULSAR_NVIDIA_VERSION_FILE:-/sys/module/nvidia/version}" 2>/dev/null) || true
    # No loaded module is check_nvidia's finding, not this one's.
    [[ "$ver" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 0
    FGL_DRIVER=$ver
    local ext="nvidia-${ver//./-}"

    local runtimes gl32_installed=0 need_gl32=0
    runtimes=$(flatpak list --runtime --columns=application 2>/dev/null) || true
    if ! grep -Fxq "org.freedesktop.Platform.GL.${ext}" <<<"$runtimes"; then
        FGL_STATUS=missing; return 0
    fi
    # GL32 lands in its own transaction after GL, ~100MB later. An app that
    # needs it before then is waiting on an install, not on a restart, and
    # telling the user to restart it got them a second Steam with the same
    # problem.
    grep -Fxq "org.freedesktop.Platform.GL32.${ext}" <<<"$runtimes" && gl32_installed=1

    local run=${PULSAR_FLATPAK_RUN:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.flatpak}
    local -a roots
    if [ -n "${PULSAR_FLATPAK_ROOTS:-}" ]; then
        read -r -a roots <<<"$PULSAR_FLATPAK_ROOTS"
    else
        roots=(/var/lib/flatpak "${XDG_DATA_HOME:-$HOME/.local/share}/flatpak")
    fi
    local inst app info exts short
    local -a apps=()

    # <GL|GL32>: does this instance hold a still-deployed nvidia extension?
    gl_live() {
        local commit r d
        commit=$(printf '%s\n' "$exts" | sed -n "s/^org\.freedesktop\.Platform\.$1\.${ext}=//p" | head -1)
        [ -n "$commit" ] || return 1
        for r in "${roots[@]}"; do
            for d in "${r}/runtime/org.freedesktop.Platform.$1.${ext}"/*/*/"${commit}"; do
                [ -d "$d" ] && return 0
            done
        done
        return 1
    }

    while IFS=$'\t' read -r inst app; do
        info="${run}/${inst}/info"
        [ -r "$info" ] || continue
        exts=$(sed -n 's/^\(runtime\|app\)-extensions=//p' "$info" | tr ';' '\n')
        # Only apps on a runtime with the GL extension point: freedesktop,
        # and GNOME and KDE, which reuse it.
        grep -q '^org\.freedesktop\.Platform\.GL\.default=' <<<"$exts" || continue
        if gl_live GL; then
            grep -q '^org\.freedesktop\.Platform\.GL32\.default=' <<<"$exts" || continue
            gl_live GL32 && continue
            [ "$gl32_installed" = 1 ] || { need_gl32=1; continue; }
        fi
        FGL_IDS+="${inst} "
        short=${app##*.}
        case " ${apps[*]-} " in *" ${short} "*) ;; *) apps+=("$short") ;; esac
    done < <(flatpak ps --columns=instance,application 2>/dev/null || true)

    if [ ${#apps[@]} -gt 0 ]; then
        FGL_STATUS=stale
        FGL_APPS=$(printf '%s\n' "${apps[@]}" | paste -sd, - | sed 's/,/, /g')
    elif [ "$need_gl32" = 1 ]; then
        FGL_STATUS=missing
    else
        FGL_STATUS=ok
    fi
}

check_flatpak_gl() {
    flatpak_gl_scan
    case "$FGL_STATUS" in
        skip) return 0 ;;
        missing)
            record flatpak-gl warn "Flatpak GL driver for NVIDIA ${FGL_DRIVER} is missing or incomplete; Flatpak games run on the wrong GPU" \
                   "sudo systemctl start pulsar-gl-nvidia.service" ;;
        stale)
            record flatpak-gl warn "${FGL_APPS} started without the NVIDIA ${FGL_DRIVER} driver" \
                   "quit fully and reopen; until then, games launched from it get the iGPU and can show a black window" ;;
        ok)
            record flatpak-gl ok "running Flatpak apps have the NVIDIA ${FGL_DRIVER} driver" ;;
    esac
}

# GPU containers: `podman run --device nvidia.com/gpu=all` resolves through a
# CDI spec, and a spec names every driver library by its full version
# (libcuda.so.615.71.09). One written for another driver still parses, still
# resolves, and then fails inside the container on files that are not there
# -- so "a spec exists" is not the check; "a spec for THIS driver" is.
#
# nvidia-cdi-refresh.service writes /var/run/cdi/nvidia.yaml every boot, and
# /var/run is tmpfs, so that one cannot go stale. The stale one is the spec a
# how-to told someone to write by hand into /etc/cdi: it survives every
# driver bump after it. Every nvidia spec in podman's search path is read.
#
# The version comes from the enable-cuda-compat hook's --host-driver-version,
# falling back to the libcuda soname. Paths are overridable for the tests;
# /sys and /proc are read directly for the reason check_nvidia gives.
check_gpu_containers() {
    local variant; variant=$(mf variant)
    case "$variant" in *nvidia*) ;; *) return 0 ;; esac
    # An image from before the toolkit shipped: nothing promised, say nothing.
    local ctk=${PULSAR_NVIDIA_CTK:-/usr/bin/nvidia-ctk}
    [ -x "$ctk" ] || return 0
    local running
    running=$(cat "${PULSAR_NVIDIA_VERSION_FILE:-/sys/module/nvidia/version}" 2>/dev/null) || true
    # No module is check_nvidia's failure to report; a second line saying
    # the same thing louder is noise.
    [ -n "$running" ] || return 0

    local dirs=${PULSAR_CDI_DIRS:-/etc/cdi /var/run/cdi}
    local d f v found=0 stale=""
    for d in $dirs; do
        for f in "$d"/*.yaml "$d"/*.json; do
            [ -f "$f" ] || continue
            grep -q 'nvidia.com/gpu' "$f" 2>/dev/null || continue
            found=$((found + 1))
            v=$(grep -o -m1 -e '--host-driver-version=[0-9.]*' "$f" 2>/dev/null | cut -d= -f2) || true
            [ -n "$v" ] || v=$(grep -o -m1 -e 'libcuda\.so\.[0-9][0-9.]*[0-9]' "$f" 2>/dev/null \
                               | sed 's/^libcuda\.so\.//') || true
            if [ "$v" != "$running" ]; then
                stale="${stale:+${stale}, }${f} (${v:-no driver version})"
            fi
        done
    done

    local sebool=${PULSAR_SELINUX_BOOLEANS:-/sys/fs/selinux/booleans}/container_use_xserver_devices
    if [ "$found" -eq 0 ]; then
        record gpu-containers warn "no CDI spec, so containers cannot be given the GPU" \
               "sudo systemctl restart nvidia-cdi-refresh.service; journalctl -b -u nvidia-cdi-refresh.service"
    elif [ -n "$stale" ]; then
        record gpu-containers warn "stale CDI spec for driver ${running}: ${stale}" \
               "delete it: the boot unit keeps /var/run/cdi current, and a spec written by hand in /etc/cdi goes stale with every driver update"
    elif [ -r "$sebool" ] && [ "$(cut -d' ' -f1 "$sebool" 2>/dev/null)" = 0 ]; then
        record gpu-containers warn "CDI spec matches ${running}, but SELinux blocks containers from the GPU" \
               "container_use_xserver_devices is off: systemctl status pulsar-gpu-containers.service"
    else
        record gpu-containers ok "CDI spec matches driver ${running}" \
               "podman run --rm --device nvidia.com/gpu=all IMAGE"
    fi
}

check_flathub() {
    have flatpak || { record flathub warn "flatpak is not installed"; return; }
    local opts
    # `|| true`: under pipefail a failing flatpak here aborted the whole
    # doctor, and --json printed nothing at all.
    opts=$(flatpak remotes --columns=name,options 2>/dev/null | awk '$1=="flathub"{ $1=""; print }') || true
    if [ -z "$opts" ]; then
        record flathub warn "flathub remote is not configured"
    elif grep -q filter <<<"$opts"; then
        # Fedora ships a filtered flathub; the whole point of the shipped
        # remotes.d file is that this system does not.
        record flathub warn "flathub is filtered" "apps outside its filter cannot be installed from it"
    else
        record flathub ok "flathub present and unfiltered"
    fi
}

# The other half of the app set. /usr/share/pulsar/flatpaks.list installs the
# stock Silverblue desktop from Fedora's `fedora` OCI remote, so a system
# without that remote cannot finish first-boot app setup at all:
# pulsar-flatpaks.service fails every fedora-remote app, the success-only
# stamp never lands, and Restart=on-failure retries every 120s indefinitely --
# the same shape as the cherenkov batch failure, minus anything on screen that
# says so. Worth a check precisely because the symptom is silence.
#
# Matched on the name alone rather than by rebuilding the options column the
# way check_flathub does. `fedora-testing` is a real remote on some systems
# and an exact match is the only thing that does not read it as this one.
check_fedora() {
    # flatpak's absence is check_flathub's finding to report; saying it twice
    # in one run is noise, not two findings.
    have flatpak || return 0
    if flatpak remotes --columns=name 2>/dev/null | grep -Fxq fedora; then
        record fedora ok "fedora remote present"
    else
        record fedora warn "fedora remote is not configured" \
               "the stock Silverblue apps cannot install; it ships at /etc/flatpak/remotes.d/fedora.flatpakrepo"
    fi
}

# What "locally modified" means, spelled once. These are the origin keys that
# `rpm-ostree install` and `rpm-ostree override` write, counted on the BOOTED
# deployment; a missing key is null and `null | length` is 0, so absent and
# empty need no separate handling. Two readers depend on this answer -- doctor
# reports it, update routes on it -- and two copies of the list would drift
# into disagreeing about the same system.
JQ_LAYERED='[ .deployments[]? | select(.booted == true) |
   ( ."requested-packages", ."requested-local-packages",
     ."requested-local-fileoverride-packages", ."requested-base-removals",
     ."requested-base-local-replacements", ."requested-modules" ) ]
 | map(length) | add // 0'

# An origin that names a DIGEST has nowhere to go: upgrading it re-pulls the
# image it is already on. Every ISO built before 2026-09-25 installed exactly
# that, because bib switches the new system onto the ref it was handed and
# build-iso.sh hands it a digest (iso-config.toml's %post now undoes it). So a
# pinned origin is a machine that will never update, and `update --check`
# comparing the digest with itself would call it up to date forever.
#
# Given `rpm-ostree status --json`, prints the command that points the booted
# deployment back at :latest, or nothing when it already follows a tag. The
# transport prefix is kept as found, so a signed origin stays signed. Three
# readers share this -- doctor, update, update --check -- so it is spelled once.
pinned_origin_fix() {
    local origin
    origin=$(printf '%s' "$1" | jq -r '[ .deployments[]? | select(.booted == true) ][0]
        | ."container-image-reference" // ""' 2>/dev/null) || return 0
    case "$origin" in
        *@sha256:*) printf 'sudo rpm-ostree rebase %s:latest\n' "${origin%@sha256:*}" ;;
    esac
}

check_origin() {
    have rpm-ostree || return 0   # check_updates reports that
    local fix
    fix=$(pinned_origin_fix "$(rpm-ostree status --json 2>/dev/null || echo '{}')")
    if [ -n "$fix" ]; then
        record origin fail "this system follows one image digest, so it will never update" "fix: ${fix}"
    else
        record origin ok "not pinned to a digest"
    fi
}

check_updates() {
    have rpm-ostree || { record updates warn "rpm-ostree not available"; return; }
    local js line staged pinned total ver lay
    js=$(rpm-ostree status --json 2>/dev/null || echo '{}')
    # A failed read used to come out as "no update staged, 0 deployment(s)":
    # health nobody verified. A booted system always has at least one.
    if ! printf '%s' "$js" | jq -e '(.deployments // []) | length > 0' >/dev/null 2>&1; then
        record updates warn "could not read deployment status" "rpm-ostree status --json"
        return
    fi
    # one jq pass for all five numbers, not five passes over the same JSON
    line=$(printf '%s' "$js" | jq -r '
      [ ([.deployments[]? | select(.staged == true)] | length),
        ([.deployments[]? | select(.pinned == true)] | length),
        (.deployments // [] | length),
        ([.deployments[]? | select(.staged == true) | .version][0] // "?"),
        ('"$JQ_LAYERED"')
      ] | map(tostring) | join("\t")' 2>/dev/null) || line=''
    [ -n "$line" ] || line=$(printf '0\t0\t0\t?\t0')
    IFS=$'\t' read -r staged pinned total ver lay <<<"$line"
    local detail="${total} deployment(s), ${pinned} pinned"
    # Worth surfacing even when everything is healthy: it changes which tool
    # `pulsar update` runs, and it is the reason an update takes minutes
    # instead of seconds.
    [ "${lay:-0}" -gt 0 ] && detail="${detail}, ${lay} layered, so updates go through rpm-ostree"
    if [ "${staged:-0}" -gt 0 ]; then
        record updates ok "update staged: ${ver}" "restart to use it"
    else
        record updates ok "no update staged" "$detail"
    fi
}

# The Pulsar code editor (the Atom fork) also ships a command called
# `pulsar`. As a Flatpak -- the normal way on this OS -- it exports only its
# app id and nothing collides. Its RPM writes /usr/bin/pulsar itself, and its
# AppImage is often linked into ~/.local/bin/pulsar, which sits earlier on PATH.
# Either way "pulsar doctor" quietly opens an editor, and an agent told by
# AGENTS.md to run `pulsar doctor --json` reads whatever that prints. Units call
# /usr/bin/pulsar by absolute path, so only an overwrite breaks them.
PULSAR_SELF_MARK="# pulsar -- the front door to a Pulsar system."
check_cli() {
    local sys=${PULSAR_SYSTEM_CLI:-/usr/bin/pulsar} first
    if [ -e "$sys" ] && ! grep -qxF "$PULSAR_SELF_MARK" "$sys" 2>/dev/null; then
        record cli fail "${sys} is not the Pulsar CLI (a layered Pulsar editor RPM?)" \
               "the update checks call it; remove the package that replaced it (rpm-ostree status)"
        return
    fi
    first=$(command -v pulsar 2>/dev/null) || first=""
    if [ -n "$first" ] && [ "$first" != "$sys" ] && ! grep -qxF "$PULSAR_SELF_MARK" "$first" 2>/dev/null; then
        record cli warn "another 'pulsar' comes first on PATH: ${first}" \
               "probably the Pulsar code editor; typing 'pulsar' runs it. Use ${sys}, or rename that one"
        return
    fi
    record cli ok "'pulsar' is this system's CLI"
}

# Staging an update writes a whole new image beside the booted one. Under
# about this much free space an upgrade starts failing in ways that look like
# network errors. Fail below it, warn below twice it. Free space in bytes, not
# percent used: 90% of a 2 TB disk is 200 GB free, and 85% of a 64 GB one is
# under 10 GB.
DISK_UPDATE_BYTES=$((10 * 1000 * 1000 * 1000))

check_disk() {
    local root=/sysroot df=${PULSAR_DF:-df}
    [ -d "$root" ] || root=/
    local pct avail gb need
    read -r pct avail < <("$df" -B1 --output=pcent,avail "$root" 2>/dev/null | tail -1) || true
    pct=${pct//[!0-9]/}
    case "$avail" in ''|*[!0-9]*) record disk warn "could not read free space on ${root}"; return ;; esac
    gb=$(awk -v b="$avail" 'BEGIN { printf "%.1f", b / 1e9 }')
    need="staging an update needs about $((DISK_UPDATE_BYTES / 1000000000)) GB free"
    if [ "$avail" -lt "$DISK_UPDATE_BYTES" ]; then
        record disk fail "${root} has ${gb} GB free" "${need}; with less, it fails, often with what looks like a network error"
    elif [ "$avail" -lt $((DISK_UPDATE_BYTES * 2)) ]; then
        record disk warn "${root} has ${gb} GB free" "$need"
    else
        record disk ok "${root} has ${gb} GB free${pct:+ (${pct}% used)}"
    fi
}

# Room to suspend: with PreserveVideoMemoryAllocations the NVIDIA driver
# writes the GPU's memory to TemporaryFilePath (/var/lib/systemd/sleep here)
# as the machine suspends, and aborts the suspend when it can't ("FBSR:
# could not reserve space"); GNOME then retries every 30 seconds and the
# machine stays awake, lid shut. Prints "<bytes>\t<path>" when it applies.
suspend_need() {
    local params=${PULSAR_NVIDIA_PARAMS:-/proc/driver/nvidia/params} smi=${PULSAR_NVIDIA_SMI:-nvidia-smi} p mib
    [ -r "$params" ] && grep -qx 'PreserveVideoMemoryAllocations: 1' "$params" || return 1
    p=$(sed -n 's/^TemporaryFilePath: "\(.*\)"$/\1/p' "$params")
    [ -n "$p" ] || p=/tmp
    mib=$("$smi" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
    [ "${mib:-0}" -gt 0 ] 2>/dev/null || return 1
    printf '%s\t%s\n' "$((mib * 1048576))" "$p"
}

# free bytes on the filesystem holding a path, or its nearest existing parent
free_bytes() {
    local p=$1 df=${PULSAR_DF:-df}
    while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
    { "$df" -B1 --output=avail "$p" 2>/dev/null || true; } | tail -1 | tr -dc 0-9
}

check_suspend_room() {
    local need path avail
    IFS=$'\t' read -r need path < <(suspend_need) || return 0
    avail=$(free_bytes "$path")
    [ -n "$avail" ] || { record suspend-room warn "could not read free space for ${path}"; return; }
    local gb_need gb_free
    gb_need=$(awk -v b="$need" 'BEGIN { printf "%.0f", b / 1e9 }')
    gb_free=$(awk -v b="$avail" 'BEGIN { printf "%.1f", b / 1e9 }')
    if [ "$avail" -lt "$need" ]; then
        record suspend-room fail "suspend will fail: ${gb_free} GB free, the GPU needs ${gb_need} GB" \
            "the NVIDIA driver saves the GPU's memory to ${path} as the machine suspends, and aborts without room; free some space (pulsar agent disk lists what agents left)"
    else
        record suspend-room ok "room to suspend: ${gb_free} GB free, the GPU needs ${gb_need} GB"
    fi
}

# Ids, in the order they run. Each is check_<id with - as _>, and each is
# the id its findings carry in --json.
DOCTOR_CHECKS='scheduler ntsync gamemode mangohud greenboot nvidia flatpak-gl gpu-faults gpu-containers flathub fedora origin updates disk suspend-room crashes cli'

doctor_help() {
    cat <<EOF
usage: pulsar doctor [check...]      health checks; exit 1 if one fails
       pulsar doctor flatpak-gl --notify
                                     also notify the desktop, once per app
                                     instance, when a running Flatpak app
                                     lacks the NVIDIA driver (pulsar-gl-check)
       pulsar doctor crashes --notify
                                     also notify, once per program per boot,
                                     with a button that asks your agent about
                                     it (pulsar-crash-watch; only with an agent)
       pulsar doctor gpu-faults --watch
                                     follow the kernel log and notify when a
                                     program hits an NVIDIA GPU fault (Xid),
                                     naming the program
                                     (pulsar-gpu-fault-watch; NVIDIA image)

checks: ${DOCTOR_CHECKS}
--json gives {checks: [{id, status, summary, detail}], ok}. A check that
does not apply here reports nothing, or status "skip" when named.
EOF
}

cmd_doctor() {
    local notify=0 watch=0 a c before
    local -a only=() run=()
    for a in "$@"; do
        case "$a" in
            -h|--help) doctor_help; return 0 ;;
            --notify) notify=1 ;;
            --watch) watch=1 ;;
            -*) die "unknown option: ${a} (see: pulsar doctor --help)" ;;
            *)
                case " ${DOCTOR_CHECKS} " in
                    *" ${a} "*) only+=("$a") ;;
                    *) die "no such check: ${a} (checks: ${DOCTOR_CHECKS})" ;;
                esac ;;
        esac
    done
    if [ "$notify" = 1 ]; then
        case "${only[*]-}" in
            flatpak-gl|crashes) ;;
            *) die "--notify goes with one check: pulsar doctor flatpak-gl --notify, or crashes --notify" ;;
        esac
    fi
    if [ "$watch" = 1 ]; then
        [ "${only[*]-}" = gpu-faults ] && [ "$notify" = 0 ] \
            || die "--watch goes with one check: pulsar doctor gpu-faults --watch"
        gpu_faults_watch
        return 0
    fi
    if [ ${#only[@]} -eq 0 ]; then
        read -ra run <<<"$DOCTOR_CHECKS"
        # the release (26.9.1) here, beside the nightly build it is running
        local rel; rel=$(mf release)
        [ "${JSON:-0}" = 1 ] || printf '%sPulsar health%s  %s%s\n\n' "$C_BOLD" "$C_RESET" \
            "${rel:+${rel} · build }" "$(mf version)"
    else
        run=("${only[@]}")
    fi
    for c in "${run[@]}"; do
        before=$RECORDED
        "check_${c//-/_}"
        # Named and silent: say so, rather than print nothing and exit 0.
        if [ ${#only[@]} -gt 0 ] && [ "$RECORDED" = "$before" ]; then
            if [ "${JSON:-0}" = 1 ]; then
                CHECK_JSON+=$(jq -n -c --arg i "$c" '{id:$i, status:"skip", summary:"does not apply on this machine", detail:""}'),
            else
                printf 'skip  %-14s does not apply on this machine\n' "$c"
            fi
        fi
    done
    [ "$notify" = 0 ] || "${only[0]//-/_}_notify"
    if [ "${JSON:-0}" = 1 ]; then
        printf '{"checks":[%s],"ok":%s}\n' "${CHECK_JSON%,}" "$([ "$RC" -eq 0 ] && echo true || echo false)"
    elif [ ${#only[@]} -eq 0 ]; then
        printf '\n'
        [ "$RC" -eq 0 ] && printf '%sno failures%s\n' "$C_OK" "$C_RESET" \
                        || printf '%sone or more checks failed%s\n' "$C_FAIL" "$C_RESET"
    fi
    return "$RC"
}

# ---------------------------------------------------------------------------
# doctor flatpak-gl --notify -- the check on its own, for pulsar-gl-check.path
# to run every time flatpak changes something. A stale app is the one
# finding here worth interrupting someone for: the next game it launches is
# black, and nothing else says why.
#
# Notifies only on `stale`. A `missing` extension is pulsar-gl-nvidia.service's
# to install, and telling the user to restart Steam before it lands would
# get them a second Steam with the same problem. When it lands, flatpak
# touches its change marker, this runs again, and the scan reads `stale`.
# ---------------------------------------------------------------------------
# Runs after check_flatpak_gl, which leaves the scan's findings in FGL_*.
flatpak_gl_notify() {
    [ "$FGL_STATUS" = stale ] || return 0

    # Once per app instance, not once per run: flatpak touches its marker
    # several times per transaction, and every one of those runs would see the
    # same stale Steam. An instance id is fresh each time an app starts, so a
    # restarted Steam that is somehow stale again still gets its warning.
    local state_file="${UPDATE_STATE}/gl-notified" seen="" id fresh=0
    if [ -r "$state_file" ]; then seen=$(cat "$state_file"); fi
    for id in $FGL_IDS; do
        case " ${seen} " in *" ${id} "*) ;; *) fresh=1 ;; esac
    done
    [ "$fresh" = 1 ] || return 0
    if have notify-send; then
        local body="Its games run on the iGPU and can show a black window. Quit it from its menu (Steam: Steam > Exit)."
        case "$FGL_APPS" in *", "*)
            body="Their games run on the iGPU and can show a black window. Quit each from its menu (Steam: Steam > Exit)." ;;
        esac
        notify-send --app-name="Pulsar" --icon=dialog-warning \
            "Restart ${FGL_APPS} to use the NVIDIA GPU" "$body" || true
    fi
    mkdir -p "$UPDATE_STATE" && printf '%s\n' "$FGL_IDS" > "$state_file"
}
