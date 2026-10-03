#!/usr/bin/env bats
# Tests for the NVIDIA GL profile pulsar-steam-gl-profile.service puts in
# the user's Steam.
#
# The bug: the Steam client stuttered on cherenkov (2026-10-03) because its
# window's GLX swaps on Xwayland blocked 20-838 ms with vsync on. Vsync off for
# the client's own process fixed it (0.2 ms swaps, a steady 240 Hz).
#
# Pinned here: the profile reaches only steamwebhelper, so no game Steam
# starts loses vsync; it changes vsync and nothing else; and the unit copies
# it to the one directory the sandboxed driver reads.

PROFILE="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/nvidia/steam-client-profile.json"
UNIT="${BATS_TEST_DIRNAME}/../system_files/usr/lib/systemd/user/pulsar-steam-gl-profile.service"

@test "the profile matches steamwebhelper by process name and nothing else" {
    run jq -c '[.rules[] | .pattern]' "$PROFILE"
    [ "$status" -eq 0 ]
    [ "$output" = '[{"feature":"procname","matches":"steamwebhelper"}]' ]
}

@test "the profile turns GL vsync off and sets nothing else" {
    run jq -c '[.profiles[].settings[]]' "$PROFILE"
    [ "$output" = '[{"key":"GLSyncToVblank","value":false}]' ]
    # every rule points at a profile that exists
    run jq -e '([.profiles[].name]) as $n | all(.rules[]; .profile as $p | $n | index($p))' "$PROFILE"
    [ "$status" -eq 0 ]
}

@test "the unit copies the shipped profile into Steam's sandboxed ~/.nv" {
    run grep -x 'ExecStart=/usr/bin/install -D -m 0644 /usr/share/pulsar/nvidia/steam-client-profile.json %h/.var/app/com.valvesoftware.Steam/.nv/nvidia-application-profiles-rc.d/50-pulsar-steam-client' "$UNIT"
    [ "$status" -eq 0 ]
    grep -qx 'ConditionPathExists=/sys/module/nvidia' "$UNIT"
}

@test "the unit is enabled for every user and in the user preset" {
    grep -q 'systemctl --global enable pulsar-steam-gl-profile.service' "${BATS_TEST_DIRNAME}/../Containerfile"
    grep -qx 'enable pulsar-steam-gl-profile.service' "${BATS_TEST_DIRNAME}/../system_files/usr/lib/systemd/user-preset/50-pulsar.preset"
}
