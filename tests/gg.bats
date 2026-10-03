#!/usr/bin/env bats
# Tests for scripts/gg and scripts/ggm, the Steam launch options, and for the
# part of `pulsar setup gamescale` that puts them in ~/.local/bin for
# launchers other than Steam, and for the image grant that makes Steam need
# none.
#
# Two things are pinned.
#
# 1. Flag forwarding. gg exists because `gamescale gamemoderun %command%`
#    hands a leading -x to gamemoderun, which tries to execute it and the game
#    never starts. So every case here asserts the exact argv gamescale
#    receives, one argument per line, so a split or merged argument shows.
#
# 2. The setup never clobbers. ~/.local/bin/gg may be someone's own script --
#    it was, on the machine these came from. A file that is not provably ours
#    must come out of setup byte-identical.

setup() {
    GG_DIR="${BATS_TEST_DIRNAME}/../scripts"
    PULSAR="${BATS_TEST_DIRNAME}/../cli/pulsar"

    BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$BIN"
    cp "${GG_DIR}/gg" "${GG_DIR}/ggm" "$BIN/"

    # gamescale records its argv and stops; gamemoderun never runs, because
    # gamescale is what would exec it.
    export ARGV_LOG="${BATS_TEST_TMPDIR}/argv"
    cat > "${BIN}/gamescale" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGV_LOG"
EOF
    chmod +x "${BIN}/gamescale"
    PATH="${BIN}:${PATH}"
}

# The argv gamescale should have received, one argument per line.
expect_argv() {
    local want got
    want=$(printf '%s\n' "$@")
    got=$(cat "$ARGV_LOG")
    if [ "$got" != "$want" ]; then
        printf 'gamescale argv\n--- want\n%s\n--- got\n%s\n' "$want" "$got" >&2
        return 1
    fi
}

@test "gg: a bare %command% path goes to gamemoderun untouched" {
    run gg "/home/u/Steam Library/game.x86_64" --fullscreen
    [ "$status" -eq 0 ]
    expect_argv gamemoderun "/home/u/Steam Library/game.x86_64" --fullscreen
}

@test "gg: a real Steam %command% is not mistaken for flags" {
    run gg /home/u/.steam/steam/ubuntu12_32/steam-launch-wrapper -- \
        /home/u/.steam/steam/ubuntu12_32/reaper SteamLaunch AppId=1091500 -- \
        "/home/u/Proton - Experimental/proton" waitforexitandrun "/games/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe" -skipStartScreen
    [ "$status" -eq 0 ]
    expect_argv gamemoderun /home/u/.steam/steam/ubuntu12_32/steam-launch-wrapper -- \
        /home/u/.steam/steam/ubuntu12_32/reaper SteamLaunch AppId=1091500 -- \
        "/home/u/Proton - Experimental/proton" waitforexitandrun "/games/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe" -skipStartScreen
}

@test "gg: -x goes to gamescale, not gamemoderun" {
    run gg -x /games/game
    [ "$status" -eq 0 ]
    expect_argv -x gamemoderun /games/game
}

@test "gg: combined short flags go through as one" {
    run gg -wn /games/game
    [ "$status" -eq 0 ]
    expect_argv -wn gamemoderun /games/game
}

@test "gg: -s takes its value with it" {
    run gg -s 1.0 /games/game
    [ "$status" -eq 0 ]
    expect_argv -s 1.0 gamemoderun /games/game
}

@test "gg: -e takes its value with it, = and all" {
    run gg -e PROTON_ENABLE_WAYLAND=1 /games/game
    [ "$status" -eq 0 ]
    expect_argv -e PROTON_ENABLE_WAYLAND=1 gamemoderun /games/game
}

@test "gg: the long forms take values too, mixed with bare flags" {
    run gg --scale 1.25 -x --env DXVK_HUD=fps /games/game
    [ "$status" -eq 0 ]
    expect_argv --scale 1.25 -x --env DXVK_HUD=fps gamemoderun /games/game
}

@test "gg: -- ends gamescale's flags and is not passed on" {
    run gg -x -- -game-that-starts-with-a-dash
    [ "$status" -eq 0 ]
    expect_argv -x gamemoderun -game-that-starts-with-a-dash
}

@test "gg: flags after the command belong to the game" {
    run gg /games/game -x -s 2
    [ "$status" -eq 0 ]
    expect_argv gamemoderun /games/game -x -s 2
}

@test "ggm: is gg with the MangoHud flag" {
    run ggm /games/game
    [ "$status" -eq 0 ]
    expect_argv -m gamemoderun /games/game
}

@test "ggm: its own flags follow -m to gamescale" {
    run ggm -x -e K=V /games/game
    [ "$status" -eq 0 ]
    expect_argv -m -x -e K=V gamemoderun /games/game
}

# ---------------------------------------------------------------------------
# pulsar setup gamescale: gg and ggm land beside gamescale in ~/.local/bin.
#
# Runs against a temporary HOME with a stub installer, and an `id` that says
# "not root", because the nightly runs this suite as root and the recipe
# refuses root.
# ---------------------------------------------------------------------------

setup_env() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"
    unset XDG_STATE_HOME GAMESCALE_BINDIR
    export PULSAR_LAUNCH_WRAPPERS="${BATS_TEST_TMPDIR}/image"
    mkdir -p "$PULSAR_LAUNCH_WRAPPERS"
    cp "${GG_DIR}/gg" "${GG_DIR}/ggm" "$PULSAR_LAUNCH_WRAPPERS/"

    export INSTALLER_LOG="${BATS_TEST_TMPDIR}/installer"
    export PULSAR_GAMESCALE_INSTALLER="${BATS_TEST_TMPDIR}/install.sh"
    cat > "$PULSAR_GAMESCALE_INSTALLER" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$INSTALLER_LOG"
exit "${INSTALLER_EXIT:-0}"
EOF
    chmod +x "$PULSAR_GAMESCALE_INSTALLER"

    cat > "${BIN}/id" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
EOF
    chmod +x "${BIN}/id"
    LB="${HOME}/.local/bin"
}

@test "setup gamescale: installs gg and ggm beside gamescale" {
    setup_env
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    [ "$(cat "$INSTALLER_LOG")" = "--platform faugus" ]
    cmp "${GG_DIR}/gg" "${LB}/gg"
    cmp "${GG_DIR}/ggm" "${LB}/ggm"
    [ -x "${LB}/gg" ] && [ -x "${LB}/ggm" ]
    [[ "$output" == *"gg %command%"* ]]
}

@test "setup gamescale: someone's own gg is left byte-identical" {
    setup_env
    mkdir -p "$LB"
    printf '#!/bin/sh\n# mine\nexec gamescale -x "$@"\n' > "${LB}/gg"
    chmod 0700 "${LB}/gg"
    cp "${LB}/gg" "${BATS_TEST_TMPDIR}/mine"
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    cmp "${BATS_TEST_TMPDIR}/mine" "${LB}/gg"
    [ "$(stat -c %a "${LB}/gg")" = 700 ]
    [[ "$output" == *"left ${LB}/gg alone"* ]]
    # and the one that was not taken still arrives
    cmp "${GG_DIR}/ggm" "${LB}/ggm"
}

@test "setup gamescale: a symlink named gg is the user's, and stays a symlink" {
    setup_env
    mkdir -p "$LB"
    cp "${GG_DIR}/gg" "${BATS_TEST_TMPDIR}/elsewhere"
    ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${LB}/gg"
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    [ -L "${LB}/gg" ]
    [ "$(readlink "${LB}/gg")" = "${BATS_TEST_TMPDIR}/elsewhere" ]
}

@test "setup gamescale: an identical gg is fine, and rerunning changes nothing" {
    setup_env
    mkdir -p "$LB"
    cp "${GG_DIR}/gg" "${LB}/gg"
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    [[ "$output" == *"${LB}/gg is current"* ]]
    [[ "$output" != *"alone"* ]]
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    cmp "${GG_DIR}/gg" "${LB}/gg"
    cmp "${GG_DIR}/ggm" "${LB}/ggm"
}

@test "setup gamescale: the copy it installed is updated when the image's changes" {
    setup_env
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    printf '# fixed upstream\n' >> "${PULSAR_LAUNCH_WRAPPERS}/gg"
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    cmp "${PULSAR_LAUNCH_WRAPPERS}/gg" "${LB}/gg"
}

@test "setup gamescale: a copy edited after install is the user's now" {
    setup_env
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    printf '# my tweak\n' >> "${LB}/gg"
    cp "${LB}/gg" "${BATS_TEST_TMPDIR}/mine"
    printf '# fixed upstream\n' >> "${PULSAR_LAUNCH_WRAPPERS}/gg"
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    cmp "${BATS_TEST_TMPDIR}/mine" "${LB}/gg"
    [[ "$output" == *"left ${LB}/gg alone"* ]]
}

@test "setup gamescale: a failed install puts nothing in ~/.local/bin" {
    setup_env
    INSTALLER_EXIT=1 run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -ne 0 ]
    [ ! -e "${LB}/gg" ]
    [ ! -e "${LB}/ggm" ]
}

@test "setup gamescale: --dry-run and --help write nothing" {
    setup_env
    run "$PULSAR" setup gamescale --dry-run --platform faugus
    [ "$status" -eq 0 ]
    [[ "$output" == *"would install ${LB}/gg"* ]]
    [ ! -e "${LB}/gg" ]
    run "$PULSAR" setup gamescale --help
    [ "$status" -eq 0 ]
    [ ! -e "${LB}/gg" ]
    [ ! -e "${HOME}/.local/state" ]
}

@test "setup gamescale: GAMESCALE_BINDIR moves gg with gamescale" {
    setup_env
    GAMESCALE_BINDIR="${HOME}/games/bin" run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    cmp "${GG_DIR}/gg" "${HOME}/games/bin/gg"
    [ ! -e "${LB}/gg" ]
}

@test "setup gamescale --uninstall: removes its own copies, never the user's" {
    setup_env
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    printf '#!/bin/sh\n# mine\n' > "${LB}/gg"
    run "$PULSAR" setup gamescale --uninstall
    [ "$status" -eq 0 ]
    [ ! -e "${LB}/ggm" ]
    [ "$(sed -n 2p "${LB}/gg")" = "# mine" ]
    [[ "$output" == *"left ${LB}/gg"* ]]
}

# ---------------------------------------------------------------------------
# Steam needs no setup: pulsar-steam-grants.service shows it the image's copies
# through host-os. What setup does for Steam is move an older home setup over.
# ---------------------------------------------------------------------------

steam_env() {
    setup_env
    export FLATPAK_LOG="${BATS_TEST_TMPDIR}/flatpak"
    cat > "${BIN}/flatpak" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >> "$FLATPAK_LOG"
EOF2
    chmod +x "${BIN}/flatpak"
    export PULSAR_GAMESCALE_SYSTEM="${BATS_TEST_TMPDIR}/image/gamescale"
    printf '#!/bin/sh\n# the image gamescale\n' > "$PULSAR_GAMESCALE_SYSTEM"
    OV="${HOME}/.local/share/flatpak/overrides/com.valvesoftware.Steam"
}

# The PATH the grant sets and the PATH setup migrates to must be one PATH.
image_path() {
    sed -n 's/.*--env=PATH=\([^ ]*\).*/\1/p' "${GG_DIR}/steam-grants.sh"
}

@test "steam-grants: merges host-os, gamescale's grants and sandbox-bin into a system override" {
    export FLATPAK_LOG="${BATS_TEST_TMPDIR}/flatpak"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$FLATPAK_LOG"\n' > "${BIN}/flatpak"
    chmod +x "${BIN}/flatpak"
    run "${GG_DIR}/steam-grants.sh"
    [ "$status" -eq 0 ]
    want='override
--system
--filesystem=host-os:ro
--filesystem=~/.local/state/gamescale:create
--talk-name=org.freedesktop.Flatpak
--env=PATH=/app/bin:/app/utils/bin:/usr/bin:/run/host/usr/lib/pulsar/sandbox-bin
com.valvesoftware.Steam'
    [ "$(cat "$FLATPAK_LOG")" = "$want" ]
}

@test "steam-grants: setup migrates to the same PATH the grant sets" {
    grep -qx "STEAM_SANDBOX_PATH=$(image_path)" "$PULSAR"
}

@test "steam-grants: the unit runs the script the image installs, every boot" {
    local unit="${BATS_TEST_DIRNAME}/../system_files/usr/lib/systemd/system/pulsar-steam-grants.service"
    grep -qx 'ExecStart=/usr/libexec/pulsar/steam-grants.sh' "$unit"
    ! grep -q '^ConditionPathExists=!' "$unit"
    grep -q 'COPY scripts/steam-grants.sh /usr/libexec/pulsar/steam-grants.sh' "${BATS_TEST_DIRNAME}/../Containerfile"
    grep -qx 'enable pulsar-steam-grants.service' "${BATS_TEST_DIRNAME}/../system_files/usr/lib/systemd/system-preset/50-pulsar.preset"
}

@test "setup gamescale: Steam alone installs nothing" {
    steam_env
    run "$PULSAR" setup gamescale
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to install"* ]]
    [[ "$output" == *"gg %command%"* ]]
    [ ! -e "$INSTALLER_LOG" ]
    [ ! -e "${LB}/gg" ] && [ ! -e "${LB}/gamescale" ]
    [ ! -e "$FLATPAK_LOG" ]
    run "$PULSAR" setup gamescale --platform steam
    [ "$status" -eq 0 ]
    [ ! -e "$INSTALLER_LOG" ]
}

@test "setup gamescale: an old Steam setup moves to the image copies" {
    steam_env
    run "$PULSAR" setup gamescale --platform faugus
    [ "$status" -eq 0 ]
    cp "$PULSAR_GAMESCALE_SYSTEM" "${LB}/gamescale"
    mkdir -p "${OV%/*}"
    printf '[Environment]\nPATH=/app/bin:/app/utils/bin:/usr/bin:%s\n' "$LB" > "$OV"
    rm -f "$INSTALLER_LOG"
    run "$PULSAR" setup gamescale
    [ "$status" -eq 0 ]
    [ "$(cat "$FLATPAK_LOG")" = "override --user --env=PATH=$(image_path) com.valvesoftware.Steam" ]
    [ ! -e "${LB}/gg" ] && [ ! -e "${LB}/ggm" ] && [ ! -e "${LB}/gamescale" ]
    [ ! -e "$INSTALLER_LOG" ]
}

@test "setup gamescale: Steam's migration leaves the user's own files" {
    steam_env
    mkdir -p "$LB"
    printf '#!/bin/sh\n# mine\n' > "${LB}/gg"
    printf '#!/bin/sh\n# an older gamescale\n' > "${LB}/gamescale"
    run "$PULSAR" setup gamescale
    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "${LB}/gg")" = "# mine" ]
    [ "$(sed -n 2p "${LB}/gamescale")" = "# an older gamescale" ]
    [[ "$output" == *"left ${LB}/gamescale"* ]]
}

@test "setup gamescale: an override already on the image PATH is not rewritten" {
    steam_env
    mkdir -p "${OV%/*}"
    printf '[Environment]\nPATH=%s\n' "$(image_path)" > "$OV"
    run "$PULSAR" setup gamescale
    [ "$status" -eq 0 ]
    [ ! -e "$FLATPAK_LOG" ]
}

@test "setup gamescale: Steam with another launcher grants only the other, and keeps gg" {
    steam_env
    run "$PULSAR" setup gamescale --platform steam faugus
    [ "$status" -eq 0 ]
    [ "$(cat "$INSTALLER_LOG")" = "--platform faugus" ]
    cmp "${GG_DIR}/gg" "${LB}/gg"
}

@test "setup gamescale: --dry-run changes nothing for Steam" {
    steam_env
    run "$PULSAR" setup gamescale --platform faugus
    mkdir -p "${OV%/*}"
    printf '[Environment]\nPATH=/usr/bin:%s\n' "$LB" > "$OV"
    run "$PULSAR" setup gamescale --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would point the PATH"* ]]
    [ -e "${LB}/gg" ]
    [ ! -e "$FLATPAK_LOG" ]
}
