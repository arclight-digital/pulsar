#!/usr/bin/env bats
# The gaming tuning drop-ins.
#
# These files have a property that makes them worth testing despite being
# static config: every one of them is a DELIBERATE DEVIATION from a default,
# and reverting any of them is silent. Nothing logs "proactive compaction is
# back on"; the machine just stutters again months later. What is pinned here
# is the value and, where it matters, the reason expressed as a constraint --
# that defrag is deferred rather than set to `always`, that the udev rule
# excludes partitions, that gamemode's override is an override and not a
# fork of the packaged file.
#
# Syntax is checked with the real parsers where they exist, because all three
# formats fail QUIETLY at the consumer: a bad sysctl key is skipped with a
# log line nobody reads, a bad udev rule disables the rest of the file, and a
# bad tmpfiles line is one boot message.

SYSCTL="system_files/usr/lib/sysctl.d/60-pulsar-gaming.conf"
TMPFILES="system_files/usr/lib/tmpfiles.d/60-pulsar-gaming.conf"
UDEV="system_files/usr/lib/udev/rules.d/60-pulsar-nvme.rules"
GAMEMODE="system_files/etc/gamemode.ini"

setup() { cd "${BATS_TEST_DIRNAME}/.." || exit 1; }

# --- sysctl -----------------------------------------------------------------

@test "sysctl: proactive compaction is off" {
    grep -qx 'vm.compaction_proactiveness = 0' "$SYSCTL"
}

@test "sysctl: the reclaim buffer is sized for this machine, not the formula" {
    # 66MB is what the kernel computes for 62GB of RAM. Anything at or below
    # that means the drop-in has stopped doing anything.
    local kb
    kb=$(sed -n 's/^vm.min_free_kbytes = //p' "$SYSCTL")
    [ -n "$kb" ]
    [ "$kb" -ge 262144 ]
}

@test "sysctl: split lock and max_map_count survived the additions" {
    grep -qx 'kernel.split_lock_mitigate = 0' "$SYSCTL"
    grep -q '^vm.max_map_count = ' "$SYSCTL"
}

@test "sysctl: every key is declared exactly once" {
    # A key set twice is a file where the reader and the kernel disagree
    # about which value is live.
    local dupes
    dupes=$(grep -oE '^[a-z_.]+ =' "$SYSCTL" | sort | uniq -d)
    [ -z "$dupes" ]
}

@test "sysctl: the file parses" {
    command -v sysctl >/dev/null || skip "no sysctl"
    run sysctl -p "$SYSCTL" --dry-run
    [ "$status" -eq 0 ]
}

# --- transparent hugepages --------------------------------------------------

@test "tmpfiles: defrag is deferred, not disabled and not forced on" {
    # defer+madvise is the whole point: MADV_HUGEPAGE still honoured, the
    # compaction moved off the faulting thread. `always` would turn THP on
    # for processes that never asked, `never` would give up the hugepages.
    grep -q 'transparent_hugepage/defrag' "$TMPFILES"
    grep -qE '^w .*/defrag .*defer\+madvise$' "$TMPFILES"
    ! grep -qE '^w .*/defrag .* (always|never)$' "$TMPFILES"
}

@test "tmpfiles: the write is type w, so a moved knob is a no-op not a failure" {
    grep -qE '^w ' "$TMPFILES"
    ! grep -qE '^w\+ ' "$TMPFILES"
}

@test "tmpfiles: enabled= is left at Fedora's madvise" {
    # Turning THP on globally is a much larger decision than this file makes.
    ! grep -q 'transparent_hugepage/enabled' "$TMPFILES"
}

@test "tmpfiles: the file parses" {
    command -v systemd-tmpfiles >/dev/null || skip "no systemd-tmpfiles"
    run systemd-tmpfiles --dry-run --create "$TMPFILES"
    [ "$status" -eq 0 ]
}

# --- nvme -------------------------------------------------------------------

@test "udev: nvme completions are pinned to the submitting cpu" {
    grep -q 'ATTR{queue/rq_affinity}="2"' "$UDEV"
}

@test "udev: partitions are excluded, which have no queue directory" {
    # Without the DEVTYPE guard every nvme0n1p* event logs a failed attribute
    # write on every boot -- noise that teaches you to ignore udev errors.
    grep -q 'ENV{DEVTYPE}=="disk"' "$UDEV"
}

@test "udev: the rule file is valid" {
    command -v udevadm >/dev/null || skip "no udevadm"
    run udevadm verify "$UDEV"
    [ "$status" -eq 0 ]
}

# --- gamemode ---------------------------------------------------------------

@test "gamemode: igpu governor demotion is disabled on this hybrid machine" {
    # The default of 0.3 throttles the CPU to powersave mid-game when the
    # iGPU/CPU power ratio trips -- a heuristic for iGPU-only machines, on a
    # box whose games run on a discrete 5080.
    grep -qx 'igpu_power_threshold=-1' "$GAMEMODE"
}

@test "gamemode: renice claims the nice grant the image already ships" {
    grep -qx 'renice=10' "$GAMEMODE"
}

@test "gamemode: the override is an override, not a copy of the package file" {
    # gamemoded merges per-key, so this file should be short and should not
    # restate defaults it agrees with. Pinning inherited values here would
    # freeze upstream's heuristics against hardware that changes.
    for key in ioprio disable_splitlock pin_cores park_cores softrealtime desiredgov; do
        ! grep -qE "^${key}=" "$GAMEMODE"
    done
}

@test "gamemode: it lives where gamemoded actually looks" {
    # The search order is /usr/share/gamemode, /etc, XDG, PWD -- later wins.
    # /usr/lib, this image's usual home for its own config, is not in it.
    [ -f "system_files/etc/gamemode.ini" ]
    [ ! -f "system_files/usr/lib/gamemode.ini" ]
}

@test "gamemode: renice is documented as needing group enrolment" {
    # renice=10 without membership is inert. The file must point at the thing
    # that fixes it, or the next reader concludes renice is broken.
    grep -q 'pulsar-gamemode-group.service' "$GAMEMODE"
}
