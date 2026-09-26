#!/usr/bin/env bats
# `pulsar theme` and the theme engine it hands to.
#
# The verb is a doorway: it must pass arguments through untouched (including
# --json and --help, which the CLI's own flag parsing would otherwise eat)
# and say plainly when the engine is not there. The engine tests stay on the
# commands that need no session bus -- list, audit, render, config -- so they
# run on a build host; what needs a live GNOME session is what
# tests/theme-gate/ is for.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    PULSAR="${REPO}/cli/pulsar"
    ENGINE="${REPO}/scripts/pulsar-theme"
    STUB="${BATS_TEST_TMPDIR}/engine"
    printf '#!/bin/sh\nprintf "%%s|" "$@"\n' > "$STUB"
    chmod +x "$STUB"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    # the checkout's themes and templates, even on a Pulsar host that has
    # its own installed under /usr/share
    export PULSAR_THEME_PATH="${REPO}/system_files/usr/share/pulsar/themes"
    export PULSAR_THEME_TEMPLATES="${REPO}/system_files/usr/share/pulsar/theme/templates"
    mkdir -p "$HOME"
}

@test "theme with no command prints its usage" {
    PULSAR_THEME_ENGINE=/nonexistent run "$PULSAR" theme
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: pulsar theme"* ]]
    [[ "$output" == *"revert"* ]]
}

@test "theme passes arguments through untouched, --json included" {
    PULSAR_THEME_ENGINE="$STUB" run "$PULSAR" theme restart-apps --json
    [ "$status" -eq 0 ]
    [ "$output" = "restart-apps|--json|" ]
}

@test "theme set passes the theme and flags through" {
    PULSAR_THEME_ENGINE="$STUB" run "$PULSAR" theme set gruvbox --variant light --no-restart
    [ "$status" -eq 0 ]
    [ "$output" = "set|gruvbox|--variant|light|--no-restart|" ]
}

@test "theme --help is the verb's usage, not the top-level one" {
    PULSAR_THEME_ENGINE="$STUB" run "$PULSAR" theme --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"usage: pulsar theme"* ]]
}

@test "theme fails cleanly when the engine is missing" {
    PULSAR_THEME_ENGINE=/nonexistent/pulsar-theme run "$PULSAR" theme list
    [ "$status" -ne 0 ]
    [[ "$output" == *"theme engine not found"* ]]
}

@test "top-level usage mentions the theme verb" {
    run "$PULSAR" --help
    [[ "$output" == *"pulsar theme <command>"* ]]
}

@test "engine lists every shipped theme, none broken, all following Dark Style" {
    run python3 "$ENGINE" list
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -ge 13 ]
    ! printf '%s\n' "$output" | grep -q '^!'
    [ "$(printf '%s\n' "$output" | grep -c '\[dark+light\]')" -eq "$(printf '%s\n' "$output" | wc -l)" ]
}

@test "every shipped theme passes the WCAG AA audit" {
    run python3 "$ENGINE" audit
    [ "$status" -eq 0 ]
    ! [[ "$output" == *FAIL* ]]
}

@test "render writes every target and leaves the real home alone" {
    out="${BATS_TEST_TMPDIR}/render"
    run python3 "$ENGINE" render pulsar "$out"
    [ "$status" -eq 0 ]
    grep -q -- '--accent-bg-color: #3ecbff' "$out/.config/gtk-4.0/gtk.css"
    grep -q 'prefers-color-scheme: light' "$out/.config/gtk-4.0/gtk.css"
    grep -q '^\[Dark\]' "$out/.local/share/org.gnome.Ptyxis/palettes/pulsar-pulsar.palette"
    [ -s "$out/.local/share/gtksourceview-5/styles/pulsar-pulsar-dark.xml" ]
    [ -s "$out/.local/state/pulsar-theme/shell/gnome-shell-dark.css" ]
    [ -s "$out/.local/state/pulsar-theme/shell/gnome-shell-light.css" ]
    [ ! -e "$HOME/.config/gtk-4.0" ]
}

@test "rendered GtkSourceView schemes are well-formed XML" {
    out="${BATS_TEST_TMPDIR}/render"
    for t in pulsar gruvbox dracula; do
        python3 "$ENGINE" render "$t" "$out" >/dev/null
    done
    for f in "$out"/.local/share/gtksourceview-5/styles/*.xml; do
        python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$f"
    done
}

@test "an unknown theme is an error, not a guess" {
    run python3 "$ENGINE" render no-such-theme "${BATS_TEST_TMPDIR}/x"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no theme 'no-such-theme'"* ]]
}

@test "restart-prompt defaults on and remembers off" {
    run python3 "$ENGINE" config
    [[ "$output" == *"restart-prompt = on"* ]]
    python3 "$ENGINE" config restart-prompt off >/dev/null
    run python3 "$ENGINE" config restart-prompt
    [[ "$output" == *"restart-prompt = off"* ]]
    grep -qx 'restart-prompt = off' "$XDG_CONFIG_HOME/pulsar/theme.conf"
}

@test "the user preset lists both theme units the Containerfile enables" {
    preset="${REPO}/system_files/usr/lib/systemd/user-preset/50-pulsar.preset"
    grep -qx 'enable pulsar-theme-init.service' "$preset"
    grep -qx 'enable pulsar-theme-notice.service' "$preset"
    grep -q 'systemctl --global enable pulsar-theme-init.service' "${REPO}/Containerfile"
    grep -q 'systemctl --global enable pulsar-theme-notice.service' "${REPO}/Containerfile"
}

@test "exactly one override sets enabled-extensions, with both extensions" {
    cd "${REPO}/system_files/usr/share/glib-2.0/schemas"
    [ "$(grep -l '^enabled-extensions=' ./*.override | wc -l)" -eq 1 ]
    grep -q "^enabled-extensions=.*'gamescale@arclight.digital'.*'pulsar-theme@arclight.digital'" zz1-pulsar-theme.gschema.override
}

@test "every theme's wallpapers are named .jxl or are brand files" {
    run grep -rhE '^(dark|light) = ' "$PULSAR_THEME_PATH"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -oE '"[^"]+"' | grep -vE '\.jxl"$|^"/usr/share/backgrounds/pulsar/'
}
