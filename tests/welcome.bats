#!/usr/bin/env bats
# The first-login welcome: who gets it, that it shows once, and that it
# replaces the theme notice rather than adding to it. The window itself needs
# a session; what is tested here is every decision around it.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    ENGINE="${REPO}/scripts/pulsar-theme"
    WELCOME="${REPO}/scripts/pulsar-welcome"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    export PULSAR_THEME_PATH="${REPO}/system_files/usr/share/pulsar/themes"
    export PULSAR_THEME_TEMPLATES="${REPO}/system_files/usr/share/pulsar/theme/templates"
    export PULSAR_THEME_FAKE_DCONF="${BATS_TEST_TMPDIR}/dconf.json"
    echo '{}' > "$PULSAR_THEME_FAKE_DCONF"
    mkdir -p "$HOME"
    TS="$XDG_STATE_HOME/pulsar-theme"
}

setkey() { python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d[sys.argv[2]]=sys.argv[3]; json.dump(d, open(f, "w"))' "$PULSAR_THEME_FAKE_DCONF" "$1" "$2"; }

have_adw() { python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); from gi.repository import Adw' 2>/dev/null; }

@test "a new account's first login queues the welcome, not the notice" {
    python3 "$ENGINE" init >/dev/null
    grep -q '"applied"' "$TS/init.json"
    grep -q '"fresh": true' "$TS/init.json"
    [ -e "$TS/welcome.pending" ]
    [ ! -e "$TS/notice.json" ]
}

@test "an account that has had a GNOME session is never greeted, and still gets the notice" {
    mkdir -p "$XDG_DATA_HOME/gnome-shell"
    python3 "$ENGINE" init >/dev/null
    grep -q '"applied"' "$TS/init.json"
    grep -q '"fresh": false' "$TS/init.json"
    [ ! -e "$TS/welcome.pending" ]
    [ -e "$TS/notice.json" ]
}

@test "xdg-user-dirs' config alone also marks an existing account" {
    mkdir -p "$XDG_CONFIG_HOME"
    : > "$XDG_CONFIG_HOME/user-dirs.dirs"
    python3 "$ENGINE" init >/dev/null
    [ ! -e "$TS/welcome.pending" ]
    [ -e "$TS/notice.json" ]
}

@test "a customised account is never new, even with no session markers" {
    setkey /org/gnome/desktop/interface/accent-color "'red'"
    python3 "$ENGINE" init >/dev/null
    grep -q '"skipped"' "$TS/init.json"
    [ ! -e "$TS/welcome.pending" ]
    [ -e "$TS/notice.json" ]
}

@test "init that already ran never queues the welcome" {
    mkdir -p "$TS"
    echo '{"result": "applied"}' > "$TS/init.json"
    python3 "$ENGINE" init >/dev/null
    [ ! -e "$TS/welcome.pending" ]
}

@test "init --force is never a first login" {
    python3 "$ENGINE" init --force >/dev/null
    [ ! -e "$TS/welcome.pending" ]
    [ -e "$TS/notice.json" ]
}

@test "a resumed init keeps the first run's fresh decision" {
    mkdir -p "$TS" "$XDG_DATA_HOME/gnome-shell"
    echo '{"decision": "apply", "theme": "pulsar", "fresh": true}' > "$TS/init.pending"
    python3 "$ENGINE" init >/dev/null
    [ -e "$TS/welcome.pending" ]
    [ ! -e "$TS/init.pending" ]
}

@test "a resumed init from before the welcome existed does not greet" {
    mkdir -p "$TS"
    : > "$TS/init.pending"
    python3 "$ENGINE" init >/dev/null
    grep -q '"applied"' "$TS/init.json"
    [ ! -e "$TS/welcome.pending" ]
    [ -e "$TS/notice.json" ]
}

@test "the first-login run stamps shown and clears the marker; later runs do nothing" {
    have_adw || skip "no PyGObject GTK 4 / libadwaita here"
    mkdir -p "$TS"
    echo '{}' > "$TS/welcome.pending"
    PULSAR_WELCOME_STAMP_ONLY=1 run python3 "$WELCOME"
    [ "$status" -eq 0 ]
    [ ! -e "$XDG_STATE_HOME/pulsar-welcome/shown.json" ]
    PULSAR_WELCOME_STAMP_ONLY=1 run python3 "$WELCOME" --first-login
    [ "$status" -eq 0 ]
    [ -s "$XDG_STATE_HOME/pulsar-welcome/shown.json" ]
    [ ! -e "$TS/welcome.pending" ]
    # a stray marker after the stamp is cleared without showing anything
    echo '{}' > "$TS/welcome.pending"
    run python3 "$WELCOME" --first-login
    [ "$status" -eq 0 ]
    [ ! -e "$TS/welcome.pending" ]
}

@test "the unit conditions on exactly the files init and the welcome write" {
    unit="${REPO}/system_files/usr/lib/systemd/user/pulsar-welcome.service"
    grep -qx 'ConditionPathExists=%S/pulsar-theme/welcome.pending' "$unit"
    grep -qx 'ConditionPathExists=!%S/pulsar-welcome/shown.json' "$unit"
    grep -qx 'ExecStart=/usr/libexec/pulsar/pulsar-welcome --first-login' "$unit"
    grep -q '^WELCOME_PENDING = "welcome.pending"$' "$ENGINE"
    grep -q 'STAMP = STATE / "pulsar-welcome" / "shown.json"' "$WELCOME"
}

@test "the welcome is copied, enabled --global and in the user preset, in lockstep" {
    cf="${REPO}/Containerfile"
    preset="${REPO}/system_files/usr/lib/systemd/user-preset/50-pulsar.preset"
    grep -qx 'enable pulsar-welcome.service' "$preset"
    grep -q 'systemctl --global enable pulsar-welcome.service' "$cf"
    grep -q '^COPY scripts/pulsar-theme .*scripts/pulsar-welcome /usr/libexec/pulsar/$' "$cf"
    grep -q 'chmod 0755 .*/usr/libexec/pulsar/pulsar-welcome' "$cf"
    # the preset assertion loop names it too
    awk '/^    for u in podman-auto-update.timer/,/; do/' "$cf" | grep -q 'pulsar-welcome.service'
    # and every --global enable has its preset line, as the build asserts
    for u in $(grep -o 'systemctl --global enable [^ ]*' "$cf" | awk '{print $4}'); do
        grep -qx "enable ${u}" "$preset"
    done
}

@test "the app-grid entry opens the welcome without --first-login" {
    d="${REPO}/system_files/usr/share/applications/digital.arclight.Pulsar.Welcome.desktop"
    grep -qx 'Name=Welcome to Pulsar' "$d"
    grep -qx 'Exec=/usr/libexec/pulsar/pulsar-welcome' "$d"
    if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$d"; fi
}

@test "GNOME's own welcome dialog is switched off by default" {
    o="${REPO}/system_files/usr/share/glib-2.0/schemas/zz0-pulsar.gschema.override"
    awk '/^\[/{s=$0} s=="[org.gnome.shell]" && /^welcome-dialog-last-shown-version=/' "$o" | grep -q "='999999'"
    s=/usr/share/glib-2.0/schemas/org.gnome.shell.gschema.xml
    if [ -r "$s" ]; then grep -q 'key name="welcome-dialog-last-shown-version"' "$s"; fi
}

@test "the welcome's brand marks are the designer's files, unchanged" {
    for m in pulsar-mark pulsar-mark-light; do
        cmp "${REPO}/assets/brand/svg/${m}.svg" "${REPO}/system_files/usr/share/pulsar/brand/${m}.svg"
    done
}

@test "the welcome compiles" {
    python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$WELCOME"
}

@test "the agents page lists agents alphabetically, split into name and maker" {
    have_adw || skip "no PyGObject GTK 4 / libadwaita here"
    run python3 - "$WELCOME" <<'PY'
import importlib.machinery, importlib.util, json, sys
path = sys.argv[1]; sys.argv = [path]
loader = importlib.machinery.SourceFileLoader("pw", path)
spec = importlib.util.spec_from_loader("pw", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
rows = m.agent_rows(json.dumps([
    {"name": "codex", "command": "codex", "state": "available", "description": "Codex CLI (OpenAI)"},
    {"name": "aider", "command": "aider", "state": "installed", "description": "aider (open source, any provider)"},
]))
print(" ".join(r["name"] for r in rows))
print(rows[1]["title"] + "|" + rows[1]["vendor"])
print(m.agent_rows("not json"))
PY
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "aider codex" ]
    [ "${lines[1]}" = "Codex CLI|OpenAI" ]
    [ "${lines[2]}" = "[]" ]
}
