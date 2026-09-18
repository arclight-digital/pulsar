#!/usr/bin/env bats
# Tests for scripts/alive-timeout.sh.
#
# The script suspends mutter's frozen-window check while a game runs. Two
# properties matter more than the happy path:
#
#   It must never block a game. Every failure mode exits 0, because gamemode
#   runs this as a start hook and a broken hook must cost the overlay of a
#   setting, not the launch.
#
#   It must put back what was THERE, not what the image ships. `gsettings
#   reset` would have been one line and would silently discard a value the
#   user set for themselves.
#
# And because a hold can leak -- gamemoded killed outright, so the end hook
# never runs -- a second hold must not overwrite the saved value, or the leak
# would bake 0 in permanently as the "original".

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/alive-timeout.sh"
    export PULSAR_ALIVE_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    STATE="${PULSAR_ALIVE_STATE_DIR}/alive-timeout.saved"

    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export GS_VALUE="${BATS_TEST_TMPDIR}/value"
    printf 'uint32 5000\n' > "$GS_VALUE"
    export GS_FAIL="${GS_FAIL:-}"
    cat > "${STUB}/gsettings" <<'EOF'
#!/bin/sh
[ -n "$GS_FAIL" ] && exit 1
case "$1" in
    get) cat "$GS_VALUE" ;;
    set) printf 'uint32 %s\n' "$4" > "$GS_VALUE" ;;
    *)   exit 1 ;;
esac
EOF
    chmod +x "${STUB}/gsettings"
    PATH="${STUB}:${PATH}"
    export PATH
}

value() { cat "$GS_VALUE"; }

@test "hold saves what was there and disables the check" {
    run "$SCRIPT" hold
    [ "$status" -eq 0 ]
    [ "$(value)" = "uint32 0" ]
    [ "$(cat "$STATE")" = "uint32 5000" ]
}

@test "release restores the saved value and clears the state" {
    "$SCRIPT" hold
    run "$SCRIPT" release
    [ "$status" -eq 0 ]
    [ "$(value)" = "uint32 5000" ]
    [ ! -f "$STATE" ]
}

@test "release restores the USER's value, not the image default" {
    # Someone who set 45000 for themselves gets 45000 back. `gsettings reset`
    # would have handed them the image's 20000 and called it restored.
    printf 'uint32 45000\n' > "$GS_VALUE"
    "$SCRIPT" hold
    [ "$(value)" = "uint32 0" ]
    "$SCRIPT" release
    [ "$(value)" = "uint32 45000" ]
}

@test "a leaked hold does not bake 0 in as the original" {
    # gamemoded killed mid-game: end never ran, state file survives, key is 0.
    "$SCRIPT" hold
    run "$SCRIPT" hold
    [ "$status" -eq 0 ]
    [[ "$output" == *"did not release"* ]]
    [ "$(cat "$STATE")" = "uint32 5000" ]
    "$SCRIPT" release
    [ "$(value)" = "uint32 5000" ]
}

@test "release with nothing held leaves the key alone" {
    printf 'uint32 12345\n' > "$GS_VALUE"
    run "$SCRIPT" release
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing held"* ]]
    [ "$(value)" = "uint32 12345" ]
}

@test "a corrupt state file is discarded rather than written into dconf" {
    mkdir -p "$PULSAR_ALIVE_STATE_DIR"
    printf 'not-a-number\n' > "$STATE"
    printf 'uint32 0\n' > "$GS_VALUE"
    run "$SCRIPT" release
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a timeout"* ]]
    [ "$(value)" = "uint32 0" ]
    [ ! -f "$STATE" ]
}

@test "a bare number in the state file is accepted" {
    mkdir -p "$PULSAR_ALIVE_STATE_DIR"
    printf '7000\n' > "$STATE"
    run "$SCRIPT" release
    [ "$status" -eq 0 ]
    [ "$(value)" = "uint32 7000" ]
}

@test "a broken gsettings costs the setting, never the game" {
    # gamemode runs this as a start hook. Exiting nonzero here must not be
    # the reason a title does not launch.
    export GS_FAIL=1
    run "$SCRIPT" hold
    [ "$status" -eq 0 ]
    run "$SCRIPT" release
    [ "$status" -eq 0 ]
}

@test "an unknown argument is a usage error, not a silent success" {
    run "$SCRIPT" wibble
    [ "$status" -eq 2 ]
    run "$SCRIPT"
    [ "$status" -eq 2 ]
}

@test "the gamemode hooks name the script this file tests" {
    local ini="${BATS_TEST_DIRNAME}/../system_files/etc/gamemode.ini"
    grep -qx 'start=/usr/libexec/pulsar/alive-timeout.sh hold' "$ini"
    grep -qx 'end=/usr/libexec/pulsar/alive-timeout.sh release' "$ini"
    grep -q 'COPY scripts/alive-timeout.sh /usr/libexec/pulsar/alive-timeout.sh' \
        "${BATS_TEST_DIRNAME}/../Containerfile"
}

@test "the global default is raised but not disabled" {
    # 0 here would remove the not-responding dialog from the whole desktop,
    # which is a different decision than the one this ships.
    local o="${BATS_TEST_DIRNAME}/../system_files/usr/share/glib-2.0/schemas/zz0-pulsar.gschema.override"
    local v
    v=$(sed -n 's/^check-alive-timeout=//p' "$o")
    [ -n "$v" ]
    [ "$v" -gt 5000 ]
    [ "$v" -ne 0 ]
}
