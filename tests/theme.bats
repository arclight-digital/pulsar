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
    [ "$(printf '%s\n' "$output" | wc -l)" -ge 16 ]
    ! printf '%s\n' "$output" | grep -q '^!'
    # every theme follows Dark Style except the one-sided ones: Dracula and
    # Alucard as upstream ships them, and the two CRT phosphors
    [ "$(printf '%s\n' "$output" | grep -vc '\[dark+light\]')" -eq 4 ]
    printf '%s\n' "$output" | grep -q '^  phosphor .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  amber .*\[dark\]$'
    printf '%s\n' "$output" | grep -q '^  dracula .*\[dark\]$'
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

@test "theme is found after global flags too" {
    PULSAR_THEME_ENGINE="$STUB" run "$PULSAR" --json theme current
    [ "$status" -eq 0 ]
    [ "$output" = "current|" ]
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
    ! grep -n 'gl_FragCoord.y \* 2.0944' "${REPO}/assets/shaders/theme.frag" "${REPO}/assets/shaders/pulsar.frag"
}

@test "each wallpaper look has its own effect in both shaders" {
    for f in "${REPO}/assets/shaders/theme.frag" "${REPO}/assets/shaders/pulsar.frag"; do
        for w in wSilk wLeak wSatin wHolo; do
            grep -q "if (${w} > 0.0)" "$f"
        done
        grep -q 'rays' "$f"; grep -q 'thread' "$f"; grep -q 'film' "$f"
    done
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
