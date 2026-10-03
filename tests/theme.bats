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

@test "engine lists every shipped theme, brand first and dark-leading, none broken" {
    run python3 "$ENGINE" list
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -ge 20 ]
    [ -z "$(printf '%s\n' "$output" | grep '^!')" ]
    # every theme follows Dark Style except the one-sided ones: Dracula,
    # Alucard, Poimandres and Synthwave '84 as upstream ships them, the
    # two CRT phosphors, and Magnetosphere and Eclipse (no aurora or
    # eclipse by day)
    [ "$(printf '%s\n' "$output" | grep -vc '\[dark+light\]')" -eq 8 ]
    printf '%s\n' "$output" | grep -q '^  magnetosphere .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  eclipse .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  phosphor .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  amber .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  dracula .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  poimandres .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  synthwave-84 .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  alucard .*\[light\]$'
    [ "$(printf '%s\n' "$output" | head -1 | awk '{print $1}')" = pulsar ]
    [ "$(printf '%s\n' "$output" | tail -1 | awk '{print $1}')" = alucard ]
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

@test "the extension's effects: its schema, every key on by default, and every screen that shows them" {
    ext="${REPO}/system_files/usr/share/gnome-shell/extensions/pulsar-theme@arclight.digital"
    xml="${REPO}/system_files/usr/share/glib-2.0/schemas/org.gnome.shell.extensions.pulsar-theme.gschema.xml"
    [ "$(jq -r '."settings-schema"' "${ext}/metadata.json")" = org.gnome.shell.extensions.pulsar-theme ]
    grep -q 'id="org.gnome.shell.extensions.pulsar-theme"' "$xml"
    for k in glass window-glass lighting power-on glow focus-brackets; do
        python3 - "$xml" "$k" <<'PY'
import sys, xml.etree.ElementTree as ET
key = ET.parse(sys.argv[1]).find(f".//key[@name='{sys.argv[2]}']")
assert key is not None and key.get("type") == "b" and key.findtext("default").strip() == "true", sys.argv[2]
PY
        grep -q "'${k}'" "${ext}/prefs.js"
        grep -q "\"${k}\"" "${REPO}/scripts/pulsar-theme-picker"
    done
    # glass off while gaming (off by default) and in Power Saver (on), on
    # both screens with the same words
    for kd in glass-off-gaming:false glass-off-power-saver:true; do
        k=${kd%%:*}
        python3 - "$xml" "$k" "${kd#*:}" <<'PY'
import sys, xml.etree.ElementTree as ET
key = ET.parse(sys.argv[1]).find(f".//key[@name='{sys.argv[2]}']")
assert key is not None and key.get("type") == "b" and key.findtext("default").strip() == sys.argv[3], sys.argv[2]
PY
        grep -q "'${k}'" "${ext}/prefs.js"
        grep -q "\"${k}\"" "${REPO}/scripts/pulsar-theme-picker"
        grep -q "'${k}'" "${ext}/glass.js"
    done
    for words in 'Disable glass when gaming' 'While a game is running' 'Disable glass in Power Saver' \
                 'While the power mode is Power Saver'; do
        grep -qF "'${words}'" "${ext}/prefs.js"
        grep -qF "\"${words}\"" "${REPO}/scripts/pulsar-theme-picker"
    done
    # the tint slider: a 0..1 double, on both screens
    grep -q '<key name="glass-tint" type="d">' "$xml"
    grep -q '<range min="0.0" max="1.0"/>' "$xml"
    grep -q "'glass-tint'" "${ext}/prefs.js"
    grep -q '"glass-tint"' "${REPO}/scripts/pulsar-theme-picker"
    # the classes glass.js toggles are the ones the Shell sheet keys off
    for c in pulsar-glass pulsar-lit; do
        grep -q "'${c}'" "${ext}/glass.js"
        grep -q "\.${c} " "${PULSAR_THEME_TEMPLATES}/gnome-shell.css"
    done
    # Glow's rules live in their own template, which the engine appends
    grep -q "'pulsar-glow'" "${ext}/glass.js"
    grep -q "\.pulsar-glow " "${PULSAR_THEME_TEMPLATES}/gnome-shell-glow.css"
}

@test "every theme's wallpapers are named .jxl or are brand files" {
    run grep -rhE '^(dark|light) = ' "$PULSAR_THEME_PATH"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -oE '"[^"]+"' | grep -vE '\.jxl"$|^"/usr/share/backgrounds/pulsar/'
}

# --- review regressions. These drive the engine for real against a JSON
# stand-in for dconf (PULSAR_THEME_FAKE_DCONF), so they never reach a session
# bus and can never write the dconf of whoever runs them.

fake_dconf() {
    export PULSAR_THEME_FAKE_DCONF="${BATS_TEST_TMPDIR}/dconf.json"
    echo '{}' > "$PULSAR_THEME_FAKE_DCONF"
}
key() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$PULSAR_THEME_FAKE_DCONF" "$1"; }
setkey() { python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d[sys.argv[2]]=sys.argv[3]; json.dump(d, open(f, "w"))' "$PULSAR_THEME_FAKE_DCONF" "$1" "$2"; }

@test "revert takes back only the managed block and our keys, keeping later user edits" {
    fake_dconf
    mkdir -p "$XDG_CONFIG_HOME/gtk-4.0" "$XDG_CONFIG_HOME/btop"
    echo '/* mine */' > "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    printf 'color_theme = "Default"\nupdate_ms = 1500\n' > "$XDG_CONFIG_HOME/btop/btop.conf"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -q 'pulsar-theme (managed' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    # the user keeps living in these files after theming
    echo 'window { opacity: 1; }' >> "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    sed -i 's/update_ms = 1500/update_ms = 500/' "$XDG_CONFIG_HOME/btop/btop.conf"
    python3 "$ENGINE" revert --to image >/dev/null
    grep -q '/\* mine \*/' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    grep -q 'opacity: 1' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    ! grep -q 'pulsar-theme' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    grep -qx 'update_ms = 500' "$XDG_CONFIG_HOME/btop/btop.conf"
    grep -qx 'color_theme = "Default"' "$XDG_CONFIG_HOME/btop/btop.conf"
    ! grep -q theme_background "$XDG_CONFIG_HOME/btop/btop.conf"
    # a gtk-3.0/gtk.css that did not exist before is gone again
    [ ! -e "$XDG_CONFIG_HOME/gtk-3.0/gtk.css" ]
}

@test "revert leaves a key the user changed after theming alone" {
    fake_dconf
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    setkey /org/gnome/desktop/interface/accent-color "'red'"
    python3 "$ENGINE" revert --to image >/dev/null
    [ "$(key /org/gnome/desktop/interface/accent-color)" = "'red'" ]
}

@test "revert keeps Ptyxis profiles, including one created since" {
    command -v ptyxis >/dev/null || [ -x /usr/bin/ptyxis ] || skip "no ptyxis here; the ptyxis target is unavailable"
    fake_dconf
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    u=$(key /org/gnome/Ptyxis/profile-uuids | tr -d "[]' ")
    setkey /org/gnome/Ptyxis/profile-uuids "['${u}', 'made-since']"
    python3 "$ENGINE" revert --to image >/dev/null
    [[ "$(key /org/gnome/Ptyxis/profile-uuids)" == *made-since* ]]
    [ -z "$(key "/org/gnome/Ptyxis/Profiles/${u}/palette")" ]
}

@test "a two-variant theme never touches Dark Style" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ "$(key /org/gnome/desktop/interface/color-scheme)" = "'default'" ]
    run python3 "$ENGINE" render pulsar "${BATS_TEST_TMPDIR}/r"
    ! [[ "$output" == *color-scheme* ]]
    # an explicit --variant is the user asking, so that one does write it
    python3 "$ENGINE" set pulsar --variant dark --no-restart >/dev/null
    [ "$(key /org/gnome/desktop/interface/color-scheme)" = "'prefer-dark'" ]
}

@test "init leaves an account with its own accent alone, and never runs twice" {
    fake_dconf
    setkey /org/gnome/desktop/interface/accent-color "'red'"
    python3 "$ENGINE" init >/dev/null
    grep -q '"skipped"' "$XDG_STATE_HOME/pulsar-theme/init.json"
    [ "$(key /org/gnome/desktop/interface/accent-color)" = "'red'" ]
    [ ! -e "$XDG_CONFIG_HOME/gtk-4.0/gtk.css" ]
    run python3 "$ENGINE" init
    [[ "$output" == *"already done"* ]]
}

@test "init after an interrupted init finishes the job instead of calling it customised" {
    fake_dconf
    # the killed run: the engine's own writes landed, no final stamp
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    : > "$XDG_STATE_HOME/pulsar-theme/init.pending"
    python3 "$ENGINE" init >/dev/null
    grep -q '"applied"' "$XDG_STATE_HOME/pulsar-theme/init.json"
    [ ! -e "$XDG_STATE_HOME/pulsar-theme/init.pending" ]
}

@test "the engine's own earlier writes do not count as customisation" {
    fake_dconf
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    python3 "$ENGINE" init >/dev/null
    grep -q '"applied"' "$XDG_STATE_HOME/pulsar-theme/init.json"
}

@test "the image sets no theme colours as defaults, only the extensions" {
    f="${REPO}/system_files/usr/share/glib-2.0/schemas/zz1-pulsar-theme.gschema.override"
    ! grep -q '^accent-color=' "$f"
    ! grep -q '^style-scheme=' "$f"
    grep -q '^enabled-extensions=' "$f"
}

@test "--with flatpak is a full switch: stale files go and the target stays on" {
    fake_dconf
    python3 "$ENGINE" set pulsar --with flatpak --no-restart >/dev/null
    st="$XDG_STATE_HOME/pulsar-theme/current.json"
    grep -q '"flatpak"' "$st"
    grep -q 'pulsar-pulsar.xml' "$st"
    python3 "$ENGINE" set gruvbox --with flatpak --no-restart >/dev/null
    [ ! -e "$XDG_DATA_HOME/gtksourceview-5/styles/pulsar-pulsar.xml" ]
    python3 "$ENGINE" bg-next >/dev/null
    grep -q '"flatpak"' "$st"
    python3 "$ENGINE" next >/dev/null
    grep -q '"flatpak"' "$st"
}

@test "names with & and quotes survive into TOML and the editor scheme" {
    printf 'system: "base16"\nname: \047Tom & "Jerry"\047\nauthor: "A <b> & c"\nvariant: "dark"\npalette:\n' > "${BATS_TEST_TMPDIR}/s.yaml"
    i=0
    for c in 1d1f21 282a2e 373b41 969896 b4b7b4 c5c8c6 e0e0e0 ffffff cc6666 de935f f0c674 b5bd68 8abeb7 81a2be b294bb a3685a; do
        printf '  base0%X: "#%s"\n' "$i" "$c" >> "${BATS_TEST_TMPDIR}/s.yaml"
        i=$((i + 1))
    done
    python3 "$ENGINE" import base16 "${BATS_TEST_TMPDIR}/s.yaml" --name tj --into "${BATS_TEST_TMPDIR}/themes" >/dev/null
    PULSAR_THEME_PATH="${BATS_TEST_TMPDIR}/themes" run python3 "$ENGINE" list
    [[ "$output" == *'Tom & "Jerry"'* ]]
    PULSAR_THEME_PATH="${BATS_TEST_TMPDIR}/themes" python3 "$ENGINE" render tj "${BATS_TEST_TMPDIR}/r" >/dev/null
    python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' \
        "${BATS_TEST_TMPDIR}/r/.local/share/gtksourceview-5/styles/pulsar-tj.xml"
}

@test "theme is found after global flags too, and --json before it reaches the engine" {
    # --json is honored or refused, never dropped: the engine decides
    PULSAR_THEME_ENGINE="$STUB" run "$PULSAR" --json theme current
    [ "$status" -eq 0 ]
    [ "$output" = "current|--json|" ]
    PULSAR_THEME_ENGINE="$STUB" run "$PULSAR" --no-logo theme set nord --json
    [ "$output" = "set|nord|--json|" ]
}

@test "nothing imports the engine through the deprecated load_module" {
    ! grep -rn 'load_module(' "${REPO}/scripts" "${REPO}/tests/theme-gate"
}

@test "Dracula and Alucard are separate one-sided themes, and choosing one sets Dark Style" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    python3 "$ENGINE" set alucard --no-restart >/dev/null
    [ "$(key /org/gnome/desktop/interface/color-scheme)" = "'default'" ]
    python3 "$ENGINE" set dracula --no-restart >/dev/null
    [ "$(key /org/gnome/desktop/interface/color-scheme)" = "'prefer-dark'" ]
    run python3 "$ENGINE" audit dracula alucard
    [ "$status" -eq 0 ]
}

onemode() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["mode"], d["name"], d["pinned"])' \
    "$XDG_STATE_HOME/pulsar-theme/shell/one-mode.json"; }

@test "a one-mode theme tells the Shell extension its mode; a two-mode theme and revert take it back" {
    fake_dconf
    lock="$XDG_STATE_HOME/pulsar-theme/shell/one-mode.json"
    python3 "$ENGINE" set dracula --no-restart >/dev/null
    [ "$(onemode)" = "dark Dracula False" ]
    python3 "$ENGINE" set alucard --no-restart >/dev/null
    [ "$(onemode)" = "light Alucard False" ]
    python3 "$ENGINE" set nord --no-restart >/dev/null
    [ ! -e "$lock" ]
    # --variant pins a two-mode theme to one: the toggle has nothing to swap to either
    python3 "$ENGINE" set nord --variant light --no-restart >/dev/null
    [ "$(onemode)" = "light Nord True" ]
    python3 "$ENGINE" set dracula --no-restart >/dev/null
    python3 "$ENGINE" revert --to image >/dev/null
    [ ! -e "$lock" ]
}

@test "every shipped theme's mode count matches what it tells the extension" {
    out="${BATS_TEST_TMPDIR}/render"
    for f in "${PULSAR_THEME_PATH}"/*/theme.toml; do
        t=$(basename "$(dirname "$f")")
        rm -rf "$out"
        python3 "$ENGINE" render "$t" "$out" >/dev/null
        modes=$(grep -cE '^\[(dark|light)\]' "$f")
        if [ "$modes" -eq 1 ]; then
            grep -q "\"mode\": \"$(grep -oE '^\[(dark|light)\]' "$f" | tr -d '[]')\"" \
                "$out/.local/state/pulsar-theme/shell/one-mode.json"
        else
            [ ! -e "$out/.local/state/pulsar-theme/shell/one-mode.json" ]
        fi
    done
}

@test "follow-scheme leaves a one-mode theme and the scheme alone after a Dark Style flip" {
    fake_dconf
    python3 "$ENGINE" set dracula --no-restart >/dev/null
    before=$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css" "$XDG_STATE_HOME/pulsar-theme/shell/"*.css | sha256sum)
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme >/dev/null
    [ "$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css" "$XDG_STATE_HOME/pulsar-theme/shell/"*.css | sha256sum)" = "$before" ]
    [ "$(key /org/gnome/desktop/interface/color-scheme)" = "'default'" ]
    [ "$(onemode)" = "dark Dracula False" ]
}

@test "revert keeps a btop theme the user picked after theming" {
    fake_dconf
    mkdir -p "$XDG_CONFIG_HOME/btop"
    printf 'color_theme = "Default"\n' > "$XDG_CONFIG_HOME/btop/btop.conf"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    sed -i 's|^color_theme = .*|color_theme = "gruvbox_dark"|' "$XDG_CONFIG_HOME/btop/btop.conf"
    python3 "$ENGINE" revert --to image >/dev/null
    grep -qx 'color_theme = "gruvbox_dark"' "$XDG_CONFIG_HOME/btop/btop.conf"
}

@test "a keyfile the engine created is gone after revert, not left as an empty group" {
    fake_dconf
    python3 "$ENGINE" set pulsar --with flatpak --no-restart >/dev/null
    [ -s "$XDG_DATA_HOME/flatpak/overrides/global" ]
    python3 "$ENGINE" revert --to image >/dev/null
    [ ! -e "$XDG_DATA_HOME/flatpak/overrides/global" ]
}

@test "flatpak is on by default, and --without keeps it off until --with" {
    fake_dconf
    st="$XDG_STATE_HOME/pulsar-theme/current.json"
    has() { python3 -c 'import json,sys; sys.exit(0 if "flatpak" in json.load(open(sys.argv[1]))["targets"] else 1)' "$st"; }
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    has
    [ -s "$XDG_DATA_HOME/flatpak/overrides/global" ]
    python3 "$ENGINE" set nord --without flatpak --no-restart >/dev/null
    ! has
    python3 "$ENGINE" set gruvbox --no-restart >/dev/null
    ! has
    python3 "$ENGINE" set gruvbox --with flatpak --no-restart >/dev/null
    has
    python3 "$ENGINE" set nord --no-restart >/dev/null
    has
}

@test "init writes no pending marker when it decides to leave an account alone" {
    fake_dconf
    setkey /org/gnome/desktop/interface/accent-color "'red'"
    python3 "$ENGINE" init >/dev/null
    [ ! -e "$XDG_STATE_HOME/pulsar-theme/init.pending" ]
    grep -q '"skipped"' "$XDG_STATE_HOME/pulsar-theme/init.json"
}

@test "restart-apps --ids looks only at the named apps" {
    run python3 "$ENGINE" restart-apps --ids org.example.NotRunning --json
    [ "$status" -eq 0 ]
    [ "$output" = '{"restart": [], "manual": []}' ]
}

@test "the engine loads through the one shared loader" {
    run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pulsar_theme_engine as m; e = m.load(); print(len(e.ordered_themes()))' "${REPO}/scripts"
    [ "$status" -eq 0 ]
    [ "$output" -ge 16 ]
    [ "$(grep -l 'def _load_engine\|SourceFileLoader(' "${REPO}"/scripts/* "${REPO}"/tests/theme-gate/*.py | grep -vc pulsar_theme_engine.py)" -eq 0 ]
}

@test "the gate fails when no report is written" {
    grep -q 'no gate-report.json was written' "${REPO}/tests/theme-gate/gate.sh"
}

@test "the phosphor themes keep every ANSI colour telling its meaning apart" {
    run python3 - "$ENGINE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
import pulsar_theme_engine as m
e = m.load(sys.argv[1])
bad = []
for slug in ("phosphor", "amber"):
    v = e.load_theme(slug).variants["dark"]
    names = ["red", "green", "yellow", "blue", "magenta", "cyan"]
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            la, lb = v[a].oklab(), v[b].oklab()
            d = sum((x - y) ** 2 for x, y in zip(la, lb)) ** 0.5
            if d < 0.08:
                bad.append(f"{slug}: {a}/{b} only {d:.3f} apart")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ]
    run python3 "$ENGINE" audit phosphor amber
    [ "$status" -eq 0 ]
}

@test "the glass rim's warning and alert lights never read as the accent, in any theme" {
    fake_dconf
    # measured on what the Shell sheet actually carries, in OKLab's a/b plane
    # (a glow's lightness is its own, so only hue and chroma tell it apart)
    run python3 - "$ENGINE" "${BATS_TEST_TMPDIR}/lights" <<'PY'
import math, re, subprocess, sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
import pulsar_theme_engine as m
e = m.load(sys.argv[1])
bad = []
for slug, t in e.ordered_themes():
    out = f"{sys.argv[2]}/{slug}"
    subprocess.run([sys.executable, sys.argv[1], "render", slug, out], check=True, capture_output=True)
    for mode, v in t.variants.items():
        css = open(f"{out}/.local/state/pulsar-theme/shell/gnome-shell-{mode}.css").read()
        rule = re.search(r"-pulsar-light: (#\w+); -pulsar-light-neutral: #\w+;\s*"
                         r"-pulsar-light-warn: (#\w+); -pulsar-light-alert: (#\w+);", css)
        if not rule:
            bad.append(f"{slug} {mode}: no light rule in the Shell sheet")
            continue
        acc, warn, alert = (e.Color.parse(x).oklab() for x in rule.groups())
        for name, c in (("warn", warn), ("alert", alert)):
            gap = math.hypot(c[1] - acc[1], c[2] - acc[2])
            if gap < 0.08:
                bad.append(f"{slug} {mode}: {name} light only {gap:.3f} from the accent")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ]
}

@test "a theme whose red and orange are clear of its accent keeps them as its lights" {
    run python3 - "$ENGINE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
import pulsar_theme_engine as m
e = m.load(sys.argv[1])
for slug in ("pulsar", "nord", "everforest", "tokyo-night"):
    for mode, v in e.load_theme(slug).variants.items():
        assert v["light_warn"].hex == v["orange"].hex, (slug, mode)
        assert v["light_alert"].hex == v["red"].hex, (slug, mode)
# the ones whose accent IS a signal color move off it
g = e.load_theme("gruvbox").variants["dark"]
assert g["light_warn"].hex != g["orange"].hex and g["light_alert"].hex != g["red"].hex
o = e.load_theme("oxocarbon").variants["light"]
assert o["light_alert"].hex != o["red"].hex
PY
    [ "$status" -eq 0 ]
}

@test "no chromatic accent maps to GNOME's grey slate, and each maps to its own hue" {
    run python3 - "$ENGINE" <<'PY'
import math, sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
import pulsar_theme_engine as m
e = m.load(sys.argv[1])
hue = lambda c: math.degrees(math.atan2(c.oklab()[2], c.oklab()[1])) % 360
bad = []
for slug, t in e.ordered_themes():
    for mode, v in t.variants.items():
        if "gnome_accent" in t.raw or "gnome_accent" in t.raw[mode]:
            continue   # the theme's own choice
        acc = v["accent"]
        _, a, b = acc.oklab()
        if math.hypot(a, b) >= 0.04 and v.gnome_accent == "slate":
            bad.append(f"{slug} {mode}: {acc.hex} is slate")
        # no other GNOME accent is nearer in hue than the one chosen
        if v.gnome_accent != "slate":
            gap = lambda n: min(abs(hue(acc) - hue(e.Color.parse(e.GNOME_ACCENTS[n]))),
                                360 - abs(hue(acc) - hue(e.Color.parse(e.GNOME_ACCENTS[n]))))
            best = min((n for n in e.GNOME_ACCENTS if n != "slate"), key=gap)
            if best != v.gnome_accent:
                bad.append(f"{slug} {mode}: {acc.hex} is {v.gnome_accent}, nearer {best}")
# the ones that came out grey before
want = {("kanagawa", "dark"): "blue", ("kanagawa", "light"): "blue", ("nord", "light"): "blue",
        ("rose-pine", "dark"): "purple", ("rose-pine", "light"): "purple"}
for (slug, mode), name in want.items():
    got = e.load_theme(slug).variants[mode].gnome_accent
    if got != name:
        bad.append(f"{slug} {mode}: {got}, not {name}")
# a grey accent is still slate
if e.nearest_gnome_accent(e.Color.parse("#808890")) != "slate":
    bad.append("a grey accent is not slate")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ]
}

@test "gnome_accent in theme.toml overrides the derived one, per variant or for both" {
    fake_dconf
    mkdir -p "$HOME/t/both" "$HOME/t/one"
    printf 'name = "B"\ngnome_accent = "slate"\n[dark]\nbackground = "#101010"\nforeground = "#e0e0e0"\naccent = "#3584e4"\n[light]\nbackground = "#f0f0f0"\nforeground = "#101010"\naccent = "#3584e4"\ngnome_accent = "teal"\n' > "$HOME/t/both/theme.toml"
    printf 'name = "O"\n[dark]\nbackground = "#101010"\nforeground = "#e0e0e0"\naccent = "#3584e4"\ngnome_accent = "mauve"\n' > "$HOME/t/one/theme.toml"
    run python3 - "$ENGINE" "$HOME/t" <<'PY'
import sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
import pulsar_theme_engine as m
e = m.load(sys.argv[1])
t = e.load_theme(sys.argv[2] + "/both")
assert t.variants["dark"].gnome_accent == "slate", t.variants["dark"].gnome_accent
assert t.variants["light"].gnome_accent == "teal", t.variants["light"].gnome_accent
try:
    e.load_theme(sys.argv[2] + "/one")
except ValueError as x:
    assert "mauve" in str(x)
else:
    sys.exit("an unknown gnome_accent loaded")
PY
    [ "$status" -eq 0 ]
}

@test "--without flatpak removes the entries the engine added, and only those" {
    fake_dconf
    f="$XDG_DATA_HOME/flatpak/overrides/global"
    mkdir -p "$(dirname "$f")"
    printf '[Context]\nfilesystems=xdg-download;\n' > "$f"
    python3 "$ENGINE" set pulsar --with flatpak --no-restart >/dev/null
    grep -q 'xdg-config/gtk-4.0:ro' "$f"
    python3 "$ENGINE" set pulsar --without flatpak --no-restart >/dev/null
    ! grep -q 'xdg-config/gtk' "$f"
    grep -q '^filesystems=xdg-download;$' "$f"
}

@test "--without flatpak deletes an override file the engine created" {
    fake_dconf
    f="$XDG_DATA_HOME/flatpak/overrides/global"
    python3 "$ENGINE" set pulsar --with flatpak --no-restart >/dev/null
    [ -s "$f" ]
    python3 "$ENGINE" set pulsar --without flatpak --no-restart >/dev/null
    [ ! -e "$f" ]
}

@test "revert keeps the user's own empty and comment-only keyfile groups" {
    fake_dconf
    f="$XDG_DATA_HOME/flatpak/overrides/global"
    mkdir -p "$(dirname "$f")"
    printf '# my overrides\n[Environment]\n\n[Session Bus Policy]\n# nothing yet\n' > "$f"
    python3 "$ENGINE" set pulsar --with flatpak --no-restart >/dev/null
    python3 "$ENGINE" revert --to image >/dev/null
    grep -qx '# my overrides' "$f"
    grep -qx '\[Environment\]' "$f"
    grep -qx '\[Session Bus Policy\]' "$f"
    grep -qx '# nothing yet' "$f"
    ! grep -q '\[Context\]' "$f"
}

@test "a non-UTF-8 btop.conf survives set and revert byte for byte" {
    fake_dconf
    mkdir -p "$XDG_CONFIG_HOME/btop"
    printf 'color_theme = "Default"\nlabel = caf\xe9\n' > "$XDG_CONFIG_HOME/btop/btop.conf"
    cp "$XDG_CONFIG_HOME/btop/btop.conf" "${BATS_TEST_TMPDIR}/orig"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -qa $'caf\xe9' "$XDG_CONFIG_HOME/btop/btop.conf"
    python3 "$ENGINE" revert --to image >/dev/null
    cmp "$XDG_CONFIG_HOME/btop/btop.conf" "${BATS_TEST_TMPDIR}/orig"
}

@test "a commit killed before its bookkeeping still counts as the engine's own write" {
    fake_dconf
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    man="$XDG_STATE_HOME/pulsar-theme/baseline/manifest.json"
    # simulate the kill window: the keys landed, `wrote` did not
    python3 - "$man" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["inflight"] = {"/org/gnome/desktop/interface/accent-color": m["wrote"].pop("/org/gnome/desktop/interface/accent-color")}
json.dump(m, open(sys.argv[1], "w"))
PY
    : > "$XDG_STATE_HOME/pulsar-theme/init.pending"
    rm -f "$XDG_STATE_HOME/pulsar-theme/init.pending"
    run python3 "$ENGINE" init
    grep -q '"applied"' "$XDG_STATE_HOME/pulsar-theme/init.json"
    python3 "$ENGINE" revert --to image >/dev/null
    [ -z "$(key /org/gnome/desktop/interface/accent-color)" ]
}

@test "a theme that does not parse lists last and next/prev skip it" {
    fake_dconf
    d="${BATS_TEST_TMPDIR}/themes"
    cp -r "$PULSAR_THEME_PATH" "$d"
    mkdir -p "$d/aaa-broken"; echo 'not = [valid' > "$d/aaa-broken/theme.toml"
    PULSAR_THEME_PATH="$d" run python3 "$ENGINE" list
    [[ "$(printf '%s\n' "$output" | tail -1)" == '! aaa-broken'* ]]
    PULSAR_THEME_PATH="$d" python3 "$ENGINE" set alucard --no-restart >/dev/null
    PULSAR_THEME_PATH="$d" python3 "$ENGINE" next >/dev/null
    grep -q '"theme": "pulsar"' "$XDG_STATE_HOME/pulsar-theme/current.json"
}

@test "no baked scanline raster in either wallpaper shader" {
    ! grep -n 'gl_FragCoord.y \* 2.0944' "${REPO}/assets/shaders/theme.frag" "${REPO}/assets/shaders/pulsar.frag" \
        "${REPO}"/assets/shaders/looks/*.glsl
}

@test "every look is its own file, in looks.json, with its own effect" {
    d="${REPO}/assets/shaders/looks"
    # looks.json: eight looks in u_look order; every file it lists exists
    [ "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["looks"]))' "$d/looks.json")" \
      = "nebula leak satin holo relief tide orbit beacon" ]
    for n in $(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["files"]))' "$d/looks.json"); do
        [ -s "$d/$n.glsl" ]
    done
    # the first three keep a brand half (pulsar.frag defines BRAND) and a theme half
    grep -q '^#define BRAND' "${REPO}/assets/shaders/pulsar.frag"
    ! grep -q '^#define BRAND' "${REPO}/assets/shaders/theme.frag"
    for n in nebula leak holo; do grep -q '^#ifdef BRAND' "$d/$n.glsl"; grep -q '^#else' "$d/$n.glsl"; done
    # each look's signature effect lives in its own file
    grep -q 'lattice' "$d/nebula.glsl"; grep -q 'rays' "$d/leak.glsl"; grep -q 'sheen' "$d/satin.glsl"
    grep -q 'film' "$d/holo.glsl"; grep -q 'isIndex' "$d/relief.glsl"; grep -q 'cellEdge' "$d/tide.glsl"
    grep -q 'ring' "$d/orbit.glsl"; grep -q 'sweep' "$d/beacon.glsl"
    # and the entries keep no look's code: only its dispatch
    ! grep -q 'beamRGB\|holoRamp\|fbm(p + 3.0' "${REPO}/assets/shaders/pulsar.frag" "${REPO}/assets/shaders/theme.frag"
}

@test "both renderers read the looks and assemble the shader from looks.json" {
    for r in render-wallpapers.py render-theme-wallpapers.py; do
        grep -q 'looks.json' "${REPO}/scripts/$r"
        grep -q 'def shader_source' "${REPO}/scripts/$r"
    done
    ! grep -q 'LOOKS = {"nebula"' "${REPO}"/scripts/render-wallpapers.py "${REPO}"/scripts/render-theme-wallpapers.py
    # every brand pair the renderer writes is registered with GNOME and the Pulsar theme
    for n in nebula leak satin holo relief tide orbit beacon; do
        grep -q "pulsar-${n}-dark.jxl" "${REPO}/system_files/usr/share/gnome-background-properties/pulsar.xml"
        grep -q "pulsar-${n}-light.jxl" "${REPO}/system_files/usr/share/pulsar/themes/pulsar/theme.toml"
    done
}

@test "Silk's old names still reach Nebula" {
    # a render table written before the rename renders the same look
    grep -q 'ALIASES = {"silk": "nebula"}' "${REPO}/scripts/render-theme-wallpapers.py"
    # and every path an account may have saved stays a link in the image:
    # the brand .png names, Silk's pair, and silk-* in each theme's backgrounds/
    grep -q 'ln -s "$(basename "${png%.png}.jxl")" "${png}"' "${REPO}/Containerfile"
    grep -q 'pulsar-silk-${v}.png' "${REPO}/Containerfile"
    grep -q '"${d}/silk-${v}.jxl"' "${REPO}/Containerfile"
    # nothing ships pointing at the old names
    ! grep -rq 'silk' "${REPO}/system_files/usr/share/glib-2.0/schemas" "${REPO}/system_files/usr/share/gnome-background-properties" "${REPO}/system_files/usr/share/pulsar/themes"
}

@test "follow-scheme rewrites only the GTK3 half after a Dark Style flip" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -q '(dark)' "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
    # gtk-theme is only set where adw-gtk3 is installed (the image; not every build host)
    adw=; [ -d /usr/share/themes/adw-gtk3 ] && adw=1
    [ -z "$adw" ] || [ "$(key /org/gnome/desktop/interface/gtk-theme)" = "'adw-gtk3-dark'" ]
    gtk4_before=$(sha256sum "$XDG_CONFIG_HOME/gtk-4.0/gtk.css")
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme >/dev/null
    grep -q '(light)' "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
    [ -z "$adw" ] || [ "$(key /org/gnome/desktop/interface/gtk-theme)" = "'adw-gtk3'" ]
    [ "$(sha256sum "$XDG_CONFIG_HOME/gtk-4.0/gtk.css")" = "$gtk4_before" ]
    # the scheme itself is the user's: follow-scheme never writes it back
    [ "$(key /org/gnome/desktop/interface/color-scheme)" = "'default'" ]
}

@test "btop gets a real theme for the scheme in effect, and follows a Dark Style flip" {
    # not the built-in TTY theme: it draws labels in ANSI white, pale on light
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    conf="$XDG_CONFIG_HOME/btop/btop.conf"
    file="$XDG_CONFIG_HOME/btop/themes/pulsar-pulsar.theme"
    grep -qx "color_theme = \"$file\"" "$conf"
    dark=$(grep '^theme\[main_fg\]' "$file")
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme >/dev/null
    grep -qx "color_theme = \"$file\"" "$conf"
    light=$(grep '^theme\[main_fg\]' "$file")
    [ -n "$dark" ] && [ -n "$light" ] && [ "$dark" != "$light" ]
    ! grep -q '"TTY"' "$conf"
}

@test "follow-scheme re-sets the system accent on a flip, and only when it changes" {
    fake_dconf
    acc=/org/gnome/desktop/interface/accent-color
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ "$(key $acc)" = "'teal'" ]
    # Pulsar is teal on dark, blue on light
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    run python3 "$ENGINE" follow-scheme
    [ "$status" -eq 0 ]
    [[ "$output" == *"-> scheme"* ]]
    [ "$(key $acc)" = "'blue'" ]
    # already right: the key is not written again
    run python3 "$ENGINE" follow-scheme
    [ "$status" -eq 0 ]
    [[ "$output" != *"scheme"* ]]
    [ "$(key $acc)" = "'blue'" ]
    # a theme whose two variants share a name never writes it on a flip
    python3 "$ENGINE" set solarized --no-restart >/dev/null
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    run python3 "$ENGINE" follow-scheme
    [ "$status" -eq 0 ]
    [[ "$output" != *"scheme"* ]]
    # an accent the user chose since is theirs, flip or no flip
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    setkey $acc "'pink'"
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme >/dev/null
    [ "$(key $acc)" = "'pink'" ]
}

@test "follow-scheme does nothing with no theme applied, or a single-mode one" {
    fake_dconf
    python3 "$ENGINE" follow-scheme
    [ ! -e "$XDG_CONFIG_HOME/gtk-3.0/gtk.css" ]
    python3 "$ENGINE" set dracula --no-restart >/dev/null
    before=$(sha256sum "$XDG_CONFIG_HOME/gtk-3.0/gtk.css")
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme
    [ "$(sha256sum "$XDG_CONFIG_HOME/gtk-3.0/gtk.css")" = "$before" ]
}

# --- agents: coding agents draw with the terminal's colors ---------------

agent_homes() {
    printf '{\n  "numStartups": 3,\n  "projects": {}\n}\n' > "$HOME/.claude.json"
    mkdir -p "$HOME/.gemini" "$XDG_CONFIG_HOME/opencode"
}
jkey() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for p in sys.argv[2].split("."): d = d.get(p) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2"; }

@test "agents: each installed agent is set to the terminal's colors, and nothing else of its config moves" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    agent_homes
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ "$(jkey "$HOME/.claude.json" theme)" = dark-ansi ]
    [ "$(jkey "$HOME/.claude.json" numStartups)" = 3 ]
    [ "$(jkey "$HOME/.gemini/settings.json" ui.theme)" = ANSI ]
    [ "$(jkey "$XDG_CONFIG_HOME/opencode/tui.json" theme)" = system ]
}

@test "agents: light avoids the ANSI themes that draw text in color 7" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    agent_homes
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ "$(jkey "$HOME/.claude.json" theme)" = light ]
    [ "$(jkey "$HOME/.gemini/settings.json" ui.theme)" = "Default Light" ]
}

@test "agents: a Dark Style flip redoes them, like GTK3" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    agent_homes
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme >/dev/null
    [ "$(jkey "$HOME/.claude.json" theme)" = light ]
}

@test "agents: none installed means no agent config is created" {
    fake_dconf
    run python3 "$ENGINE" set pulsar --no-restart
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.claude.json" ]
    [ ! -e "$HOME/.gemini" ]
    [ ! -e "$XDG_CONFIG_HOME/opencode/tui.json" ]
}

@test "agents: revert takes back only the theme key, keeps a later choice, and removes files it made" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    agent_homes
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    # the user picks their own theme in opencode afterwards
    printf '{"theme": "tokyonight"}\n' > "$XDG_CONFIG_HOME/opencode/tui.json"
    python3 "$ENGINE" revert --to image >/dev/null
    [ -z "$(jkey "$HOME/.claude.json" theme)" ]
    [ "$(jkey "$HOME/.claude.json" numStartups)" = 3 ]
    [ ! -e "$HOME/.gemini/settings.json" ]
    [ "$(jkey "$XDG_CONFIG_HOME/opencode/tui.json" theme)" = tokyonight ]
}

@test "agents: a config that is not JSON is left alone" {
    fake_dconf
    printf 'not json {' > "$HOME/.claude.json"
    run python3 "$ENGINE" set pulsar --no-restart
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/.claude.json")" = "not json {" ]
}

# --- the user's own choices, and runs nobody asked for -------------------

@test "follow-scheme leaves a btop theme and an agent theme chosen since alone" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    agent_homes
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    conf="$XDG_CONFIG_HOME/btop/btop.conf"
    sed -i 's|^color_theme = .*|color_theme = "gruvbox_dark"|' "$conf"
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["theme"]="dark-daltonized"; json.dump(d, open(p, "w"))' "$HOME/.claude.json"
    setkey /org/gnome/desktop/interface/color-scheme "'default'"
    python3 "$ENGINE" follow-scheme >/dev/null
    grep -qx 'color_theme = "gruvbox_dark"' "$conf"
    [ "$(jkey "$HOME/.claude.json" theme)" = dark-daltonized ]
    # the one the user did not touch still follows the flip
    [ "$(jkey "$HOME/.gemini/settings.json" ui.theme)" = "Default Light" ]
    grep -q '(light)' "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
    # and a full set is the user asking: it does overwrite
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ "$(jkey "$HOME/.claude.json" theme)" = light ]
}

@test "first login keeps an agent theme the user chose before, and an editor scheme counts as their own look" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    printf '{"theme": "dark-daltonized"}\n' > "$HOME/.claude.json"
    python3 "$ENGINE" init >/dev/null
    grep -q '"applied"' "$XDG_STATE_HOME/pulsar-theme/init.json"
    [ "$(jkey "$HOME/.claude.json" theme)" = dark-daltonized ]
    rm -rf "$XDG_STATE_HOME/pulsar-theme"
    fake_dconf
    setkey /org/gnome/TextEditor/style-scheme "'classic'"
    python3 "$ENGINE" init >/dev/null
    grep -q '"skipped"' "$XDG_STATE_HOME/pulsar-theme/init.json"
    grep -q 'editor color scheme' "$XDG_STATE_HOME/pulsar-theme/init.json"
}

@test "revert keeps extensions enabled since theming, and a list the engine never wrote" {
    fake_dconf
    setkey /org/gnome/shell/enabled-extensions "['mine@user']"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [[ "$(key /org/gnome/shell/enabled-extensions)" == *pulsar-theme@arclight.digital* ]]
    setkey /org/gnome/shell/enabled-extensions "['mine@user', 'pulsar-theme@arclight.digital', 'new@user']"
    python3 "$ENGINE" revert --to image >/dev/null
    [ "$(key /org/gnome/shell/enabled-extensions)" = "['mine@user', 'new@user']" ]
    # already on before theming: the engine never wrote the list, revert never touches it
    fake_dconf
    rm -rf "$XDG_STATE_HOME/pulsar-theme"
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital', 'x@user']"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    python3 "$ENGINE" revert --to image >/dev/null
    [ "$(key /org/gnome/shell/enabled-extensions)" = "['pulsar-theme@arclight.digital', 'x@user']" ]
}

@test "render touches nothing under the real home, agent configs and the Flatpak editor included" {
    printf '{"theme": "light-daltonized"}\n' > "$HOME/.claude.json"
    mkdir -p "$HOME/.gemini" "$HOME/.var/app/org.gnome.TextEditor" "$XDG_CONFIG_HOME/opencode"
    before=$(cd "$HOME" && find . -printf '%p %s\n' | sort | sha256sum)
    run python3 "$ENGINE" render dracula "${BATS_TEST_TMPDIR}/out"
    [ "$status" -eq 0 ]
    [ "$(cd "$HOME" && find . -printf '%p %s\n' | sort | sha256sum)" = "$before" ]
    [ "$(cat "$HOME/.claude.json")" = '{"theme": "light-daltonized"}' ]
    [ -s "${BATS_TEST_TMPDIR}/out/.config/gtk-4.0/gtk.css" ]
}

@test "a lone surrogate in an agent's JSON survives set, still escaped, and the rest stays UTF-8" {
    fake_dconf
    setkey /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
    printf '{"history": [{"display": "x \\ud83d"}], "e": "\xc3\xa9"}\n' > "$HOME/.claude.json"
    run python3 "$ENGINE" set pulsar --no-restart
    [ "$status" -eq 0 ]
    grep -qF '"display": "x \ud83d"' "$HOME/.claude.json"
    grep -q '"e": "é"' "$HOME/.claude.json"
    [ "$(jkey "$HOME/.claude.json" theme)" = dark-ansi ]
}

@test "a dotfile symlinked inside home is written through and stays a link, with its mode" {
    fake_dconf
    mkdir -p "$HOME/dots" "$XDG_CONFIG_HOME/gtk-4.0" "$XDG_CONFIG_HOME/btop"
    echo '/* mine */' > "$HOME/dots/gtk.css"
    chmod 644 "$HOME/dots/gtk.css"
    ln -s ../../dots/gtk.css "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    printf 'update_ms = 1500\n' > "$XDG_CONFIG_HOME/btop/btop.conf"
    chmod 640 "$XDG_CONFIG_HOME/btop/btop.conf"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ -L "$XDG_CONFIG_HOME/gtk-4.0/gtk.css" ]
    grep -q 'pulsar-theme (managed' "$HOME/dots/gtk.css"
    [ "$(stat -c %a "$HOME/dots/gtk.css")" = 644 ]
    [ "$(stat -c %a "$XDG_CONFIG_HOME/btop/btop.conf")" = 640 ]
    python3 "$ENGINE" revert --to image >/dev/null
    [ -L "$XDG_CONFIG_HOME/gtk-4.0/gtk.css" ]
    [ "$(cat "$HOME/dots/gtk.css")" = '/* mine */' ]
}

@test "a dotfile symlinked out of home is neither written through nor replaced" {
    fake_dconf
    mkdir -p "${BATS_TEST_TMPDIR}/store" "$XDG_CONFIG_HOME/gtk-4.0"
    echo '/* managed elsewhere */' > "${BATS_TEST_TMPDIR}/store/gtk.css"
    ln -s "${BATS_TEST_TMPDIR}/store/gtk.css" "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    run python3 "$ENGINE" set pulsar --no-restart
    [ "$status" -eq 0 ]
    [[ "$output" == *"links outside your home folder"* ]]
    [ -L "$XDG_CONFIG_HOME/gtk-4.0/gtk.css" ]
    [ "$(cat "${BATS_TEST_TMPDIR}/store/gtk.css")" = '/* managed elsewhere */' ]
    # the rest of the theme still lands
    grep -q 'pulsar-theme (managed' "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
}

@test "glass windows follow the Glass tint slider, a step more opaque than the Shell's glass" {
    fake_dconf
    setkey /org/gnome/shell/extensions/pulsar-theme/glass true
    setkey /org/gnome/shell/extensions/pulsar-theme/window-glass true
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital']"
    # clear: the Shell's glass at 0.35, windows at 0.42
    setkey /org/gnome/shell/extensions/pulsar-theme/glass-tint 0.0
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -q -- '--window-bg-color: alpha(#[0-9a-f]*, 0.42)' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    # the default: 0.72, as windows had before they followed the slider
    setkey /org/gnome/shell/extensions/pulsar-theme/glass-tint 0.5
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -q -- '--window-bg-color: alpha(#[0-9a-f]*, 0.72)' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    # fully tinted: capped at 0.95, never opaque, or the blur would be pointless
    setkey /org/gnome/shell/extensions/pulsar-theme/glass-tint 1.0
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -q -- '--window-bg-color: alpha(#[0-9a-f]*, 0.95)' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
}

# Stock-grey leaks: a state stock styles with its own grey (`.button:active:hover`)
# on a control the Shell sheet names beats the sheet's shorter rule and shows
# as a grey slab. tests/theme-gate/stock_states.py reads this machine's stock
# sheet; a build host without GNOME Shell has nothing to compare against.
@test "no stock state keeps stock's grey on a control the Shell sheet names" {
    run python3 "${REPO}/tests/theme-gate/stock_states.py" check
    [ "$status" -ne 77 ] || skip "no gnome-shell-theme.gresource here"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the generated stock-states block is what the script writes today" {
    run python3 "${REPO}/tests/theme-gate/stock_states.py" emit
    [ "$status" -ne 77 ] || skip "no gnome-shell-theme.gresource here"
    [ "$status" -eq 0 ]
    tpl="${REPO}/system_files/usr/share/pulsar/theme/templates/gnome-shell.css"
    got=$(sed -n '/^\/\* BEGIN stock states/,/^\/\* END stock states \*\//p' "$tpl")
    [ "$got" = "$output" ] || { diff <(echo "$output") <(echo "$got"); false; }
}

@test "glow: the Shell's rules are always written under .pulsar-glow, GTK's only while the switch is on" {
    fake_dconf
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital']"
    setkey /org/gnome/shell/extensions/pulsar-theme/glow true
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    grep -q -- 'check:indeterminate:not(:disabled)' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    grep -q -- 'treeview check:checked:not(:disabled)' "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
    grep -q '^\.pulsar-glow \.slider { -pulsar-glow: rgba(' "$XDG_STATE_HOME/pulsar-theme/shell/gnome-shell-dark.css"
    # off: GTK loses its block; the Shell keeps its rules, which the extension
    # switches with the class
    setkey /org/gnome/shell/extensions/pulsar-theme/glow false
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    ! grep -q -- 'check:indeterminate:not(:disabled)' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    ! grep -q -- 'treeview check:checked:not(:disabled)' "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
    grep -q '\.pulsar-glow \.quick-toggle:checked' "$XDG_STATE_HOME/pulsar-theme/shell/gnome-shell-dark.css"
    # high contrast wins over the switch
    setkey /org/gnome/shell/extensions/pulsar-theme/glow true
    setkey /org/gnome/desktop/a11y/interface/high-contrast true
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    ! grep -q -- 'check:indeterminate:not(:disabled)' "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
}

# The generated block must open the sheet: at equal specificity the later
# rule wins, and a generated `.button:checked` after `.quick-toggle:checked`
# turned every checked quick toggle grey (1a704c7). Every hand-written rule
# comes after it, so the theme's own rules win every tie.
@test "the generated stock-states block opens the Shell sheet" {
    tpl="${REPO}/system_files/usr/share/pulsar/theme/templates/gnome-shell.css"
    begin=$(grep -n '^/\* BEGIN stock states' "$tpl" | cut -d: -f1)
    first=$(grep -n '{' "$tpl" | head -1 | cut -d: -f1)
    [ -n "$begin" ]
    [ "$begin" -lt "$first" ]
}

@test "an image update's new templates reach a theme set before it, once, at the next login" {
    fake_dconf
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital']"
    tpl="${BATS_TEST_TMPDIR}/templates"
    cp -r "$PULSAR_THEME_TEMPLATES" "$tpl"
    export PULSAR_THEME_TEMPLATES="$tpl"
    sheet="$XDG_STATE_HOME/pulsar-theme/shell/gnome-shell-dark.css"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    ! grep -q 'pulsar-new-surface' "$sheet"
    # nothing changed: the extension's check at login redoes nothing
    before=$(stat -c %Y.%i "$sheet")
    python3 "$ENGINE" window-glass --if-stale >/dev/null
    [ "$(stat -c %Y.%i "$sheet")" = "$before" ]
    # the next image learns a surface
    echo '.pulsar-new-surface { -pulsar-light: {{accent}}; }' >> "$tpl/gnome-shell.css"
    python3 "$ENGINE" window-glass --if-stale >/dev/null
    grep -q '^\.pulsar-new-surface { -pulsar-light: #' "$sheet"
    # and only once
    before=$(stat -c %Y.%i "$sheet")
    python3 "$ENGINE" window-glass --if-stale >/dev/null
    [ "$(stat -c %Y.%i "$sheet")" = "$before" ]
}

# Glass windows reach menus, popovers and dialogs. Popovers and floating
# dialogs are windows of their own (the extension blurs behind them); a
# dialog or a toast inside its window can only be blurred by GTK itself, so
# it is solid unless GTK is new enough to (the reduced-motion gate).
@test "glass: popovers and floating dialogs go translucent, in-window sheets and toasts solid then gated glass" {
    fake_dconf
    setkey /org/gnome/shell/extensions/pulsar-theme/glass true
    setkey /org/gnome/shell/extensions/pulsar-theme/window-glass true
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital']"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    css="$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    # a step more opaque than the window ground (0.72 at the default tint)
    grep -q -- '--popover-bg-color: alpha(#[0-9a-f]*, 0.77)' "$css"
    grep -q -- '--dialog-bg-color: alpha(#[0-9a-f]*, 0.77)' "$css"
    # every GTK: the in-window sheet solid, inside each variant's block
    grep -q '^dialog-host > dialog floating-sheet > sheet, dialog-host > dialog bottom-sheet > sheet {$' "$css"
    grep -q '^toast { background-color: #[0-9a-f]*; color: #[0-9a-f]*; }$' "$css"
    # fullscreen has no blur behind it: its grounds solid
    grep -A1 '^window.fullscreen {$' "$css" | grep -q -- '^  --window-bg-color: #[0-9a-f]*;$'
    # GTK 4.22: glass, in top-level blocks only a GTK that knows reduced motion keeps
    [ "$(grep -c '^@media (prefers-color-scheme: \(light\|dark\)) and (prefers-reduced-motion: no-preference), (prefers-color-scheme: \(light\|dark\)) and (prefers-reduced-motion: reduce) {$' "$css")" -eq 2 ]
    [ "$(grep -c 'backdrop-filter: blur(20px) url("pulsar-backdrop.svg#opaque");' "$css")" -eq 6 ]
    # the gated blocks come last, so they win over the solid ones
    last_solid=$(grep -n '^toast { background-color' "$css" | tail -1 | cut -d: -f1)
    first_gate=$(grep -n 'prefers-reduced-motion' "$css" | head -1 | cut -d: -f1)
    [ "$last_solid" -lt "$first_gate" ]
    # and the filter they name sits beside gtk.css
    grep -q 'feFuncA type="linear" slope="0" intercept="1"' "$XDG_CONFIG_HOME/gtk-4.0/pulsar-backdrop.svg"
}

@test "glass off: popovers and dialogs opaque, toasts still themed, no sheet glass" {
    fake_dconf
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    css="$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    grep -q -- '--popover-bg-color: #[0-9a-f]*;' "$css"
    grep -q -- '--dialog-bg-color: #[0-9a-f]*;' "$css"
    grep -q '^toast { background-color: #[0-9a-f]*; color: #[0-9a-f]*; }$' "$css"
    ! grep -q 'dialog-host\|backdrop-filter\|prefers-reduced-motion' "$css"
    [ ! -e "$XDG_CONFIG_HOME/gtk-4.0/pulsar-backdrop.svg" ]
}

@test "glass: the filter the Glass windows switch writes is revert's to take back" {
    fake_dconf
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital']"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    [ ! -e "$XDG_CONFIG_HOME/gtk-4.0/pulsar-backdrop.svg" ]
    setkey /org/gnome/shell/extensions/pulsar-theme/glass true
    setkey /org/gnome/shell/extensions/pulsar-theme/window-glass true
    python3 "$ENGINE" window-glass >/dev/null
    [ -e "$XDG_CONFIG_HOME/gtk-4.0/pulsar-backdrop.svg" ]
    python3 "$ENGINE" revert --to image >/dev/null
    [ ! -e "$XDG_CONFIG_HOME/gtk-4.0/pulsar-backdrop.svg" ]
}

# GTK's own parser on the rendered gtk.css: no errors, and the gated glass
# kept by a GTK that has backdrop-filter. Skipped without GTK 4 bindings.
@test "glass: GTK parses the rendered gtk.css cleanly" {
    python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' 2>/dev/null ||
        skip "no GTK 4 bindings here"
    fake_dconf
    setkey /org/gnome/shell/extensions/pulsar-theme/glass true
    setkey /org/gnome/shell/extensions/pulsar-theme/window-glass true
    setkey /org/gnome/shell/enabled-extensions "['pulsar-theme@arclight.digital']"
    python3 "$ENGINE" set pulsar --no-restart >/dev/null
    run python3 "${REPO}/tests/fixtures/gtk-css-parse.py" "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
    [ "$status" -eq 0 ]
    [[ "$output" == *"errors: []"* ]]
    # a GTK that has backdrop-filter keeps it; an older one drops the block
    [[ "$output" == *"gated: True True"* || "$output" == *"gated: False False"* ]]
}

# The theme gate's own judgments, without a Shell: tests/theme-gate/scenario.py
# imported for its pure functions.
gate_py() {
    GATE_OUT="${BATS_TEST_TMPDIR}/out" GATE_APPS_LOG="${BATS_TEST_TMPDIR}/apps.log" \
        GATE_SHELL_LOG="${BATS_TEST_TMPDIR}/shell.log" \
        python3 -c "import sys; sys.path.insert(0, '${REPO}/tests/theme-gate'); import scenario as s; $1"
}

@test "theme gate: a pulsar-theme warning or a JS error in the Shell log fails it" {
    printf '%s\n' '(gnome-shell:49): libmutter-WARNING **: There is no colord server available' > "${BATS_TEST_TMPDIR}/shell.log"
    run gate_py 'print(s.shell_log_problems("t"))'
    [ "$output" = "[]" ]
    printf '%s\n' '(gnome-shell:49): GNOME Shell-WARNING **: 23:31:09.539: pulsar-theme: glass: menu: boom' \
        'JS ERROR: TypeError: x is undefined' >> "${BATS_TEST_TMPDIR}/shell.log"
    run gate_py 'print(len(s.shell_log_problems("t")))'
    [ "$output" = "2" ]
    # and the log is kept beside the report
    [ -s "${BATS_TEST_TMPDIR}/out/t-shell.log" ]
}

@test "theme gate: glass off its host, missing or hidden fails the glass scenario" {
    run gate_py '
import copy
host = [100, 100, 200, 80]
good = {"name": "m", "kind": "surface", "host": host, "shown": True, "opacity": 255, "box": [100, 106, 200, 74],
        "under": {"rect": host, "visible": True, "mapped": True, "opacity": 255, "parent": True, "beside": True},
        "over": {"rect": host, "visible": True, "mapped": True, "opacity": 255, "parent": True, "beside": True},
        "blur": {"rect": [36, 42, 328, 202], "visible": True, "mapped": True},
        "light": {"rect": [52, 58, 296, 170], "visible": True, "mapped": True}}
def bad(fn):
    r = copy.deepcopy(good); fn(r); return bool(s.glass_faults(r))
print(s.glass_faults(good) == [],
      bad(lambda r: r["under"].update(rect=[103, 100, 200, 80])),
      bad(lambda r: r["over"].update(beside=False)),
      bad(lambda r: r["blur"].update(visible=False)),
      bad(lambda r: r["light"].update(rect=[62, 58, 296, 170])),
      bad(lambda r: r.update(under=None)),
      bad(lambda r: r.update(host=[None, 100, 200, 80])),
      bad(lambda r: r.update(error="no glass surface for it")))
win = {"name": "w", "kind": "window", "frame": [60, 80, 1000, 700], "shown": True,
       "blur": {"rect": [12, 32, 1096, 796], "visible": True, "mapped": True, "inWindow": True}}
print(s.glass_faults(win) == [], bool(s.glass_faults(dict(win, blur=dict(win["blur"], rect=[22, 32, 1096, 796])))))'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "${lines[0]}" = "True True True True True True True True" ]
    [ "${lines[1]}" = "True True" ]
}

@test "theme gate: leaks --contrast judges text over the grounds beneath it, and not text on glass" {
    run gate_py '
run = {"m: menu|": ["255,255,255,255", None, None, None],
       "m: menu > box[0]|": ["0,0,0,20", None, None, None],
       "m: menu > box[0] > label[0]|": [None, "119,119,119,255", None, None],
       "m: menu > box[0] > label[1]|": [None, "0,0,0,255", None, None],
       "g: glass|": ["30,30,30,128", None, None, None],
       "g: glass > label[0]|": [None, "255,255,255,255", None, None]}
bad, judged, unjudged = s.low_contrast(run)
print([b["path"] for b in bad], judged, unjudged)'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$output" = "['menu > box[0] > label[0]'] 2 1" ]
}
