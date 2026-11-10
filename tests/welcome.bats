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

fail() { echo "$*" >&2; return 1; }

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

@test "the login screen's accounts get no first-login setup, welcome or notice" {
    XDG_SESSION_CLASS=greeter run python3 "$ENGINE" init
    [ "$status" -eq 0 ]
    [ ! -e "$TS/init.json" ] && [ ! -e "$TS/welcome.pending" ] && [ ! -e "$TS/notice.json" ]
    XDG_SESSION_CLASS=greeter run python3 "$ENGINE" login-account
    [ "$status" -eq 1 ]
    run python3 "$ENGINE" login-account
    [ "$status" -eq 0 ]
    # GDM's dynamic greeter users, by name and by UID, and the static gdm user
    run python3 -c '
import pwd, sys, types
sys.path.insert(0, sys.argv[1]); import pulsar_theme_engine as m; e = m.load()
real = e.os.getuid
for name, uid, want in [("gdm-greeter", 60578, False), ("gdm-greeter-3", 60580, False), ("gdm", 42, False),
                        ("nick", 1000, True), ("someone", 60600, False)]:
    e.pwd = types.SimpleNamespace(getpwuid=lambda _u, n=name: types.SimpleNamespace(pw_name=n))
    e.os.getuid = lambda u=uid: u
    assert e.login_account() is want, (name, uid)
e.os.getuid = real
print("ok")' "${REPO}/scripts"
    [ "$status" -eq 0 ] && [ "$output" = ok ]
    # the units: the static gdm user by condition, the welcome through the engine
    U="${REPO}/system_files/usr/lib/systemd/user"
    for u in pulsar-theme-init pulsar-theme-notice pulsar-welcome; do grep -qx 'ConditionUser=!@system' "$U/$u.service"; done
    grep -qx 'ExecCondition=/usr/libexec/pulsar/pulsar-theme login-account' "$U/pulsar-welcome.service"
}

@test "init looks at the account before xdg-user-dirs writes into it" {
    # On Fedora 45 xdg-user-dirs.service writes ~/.config/user-dirs.dirs, a
    # first-login mark, in the same instant init starts; unordered, it won,
    # and no new account was ever greeted.
    unit="${REPO}/system_files/usr/lib/systemd/user/pulsar-theme-init.service"
    grep -qx 'Before=xdg-user-dirs.service' "$unit"
    grep -qx 'Before=gnome-session-pre.target' "$unit"
    # and that file is still one of the marks: an account that has it is not new
    mkdir -p "$XDG_CONFIG_HOME"; : > "$XDG_CONFIG_HOME/user-dirs.dirs"
    python3 "$ENGINE" init >/dev/null
    grep -q '"fresh": false' "$TS/init.json"
    [ ! -e "$TS/welcome.pending" ]
}

# ---------------------------------------------------------------------------
# What's new: the notes for this release, and one notice per release
# ---------------------------------------------------------------------------
WHATS_NEW="${BATS_TEST_DIRNAME}/../scripts/pulsar_whats_new.py"

news_env() {
    export PULSAR_RELEASE_FILE="${BATS_TEST_TMPDIR}/release" PULSAR_RELEASE_NOTES="${BATS_TEST_TMPDIR}/releases.md"
    cat > "$PULSAR_RELEASE_NOTES" <<'MD'
# Releases

Intro that is not a release.

## 26.12.1

Snow, and `pulsar snow` for it.

### Desktop

- Snow falls on the **top bar**, as
  [documented](https://example.invalid) & tested.
- Second <point>.

### Gaming

- `gg` is faster.

## 26.11.1

Older.
MD
    echo 26.12.1 > "$PULSAR_RELEASE_FILE"
    STUB="${BATS_TEST_TMPDIR}/stub"; mkdir -p "$STUB"
    export NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log" CLICK=""
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "$NOTIFY_LOG"\n[ -n "$CLICK" ] && echo open\nexit 0\n' > "${STUB}/notify-send"
    printf '#!/bin/sh\necho "welcome $*" > "%s/opened"\n' "$BATS_TEST_TMPDIR" > "${STUB}/welcome"
    chmod +x "${STUB}/notify-send" "${STUB}/welcome"
    export PATH="${STUB}:${PATH}" PULSAR_WELCOME="${STUB}/welcome"
}

@test "what's new: the release's own section of the notes, as markup" {
    news_env
    run python3 "$WHATS_NEW" --print
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "26.12.1: Snow, and <tt>pulsar snow</tt> for it." ]
    [ "${lines[1]}" = "Desktop" ]
    # a bullet's wrapped lines joined; bold, links and what Pango would read as tags
    [ "${lines[2]}" = "  - Snow falls on the <b>top bar</b>, as documented &amp; tested." ]
    [ "${lines[3]}" = "  - Second &lt;point&gt;." ]
    [ "${lines[4]}" = "Gaming" ]
    [ "${lines[5]}" = "  - <tt>gg</tt> is faster." ]
    [ "${#lines[@]}" -eq 6 ]
    echo 99.1.1 > "$PULSAR_RELEASE_FILE"
    run python3 "$WHATS_NEW" --print
    [ "$status" -eq 1 ]
}

@test "what's new: the shipped notes have a section for the shipped release" {
    run env PULSAR_RELEASE_FILE="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/release" \
        PULSAR_RELEASE_NOTES="${BATS_TEST_DIRNAME}/../docs/releases.md" python3 "$WHATS_NEW" --print
    [ "$status" -eq 0 ] || fail "the release in system_files/usr/share/pulsar/release has no section in docs/releases.md"
    [[ "${lines[0]}" == "$(cat "${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/release"): "?* ]]
}

@test "what's new: an updated account is told once per release, and the button opens the page" {
    news_env
    run python3 "$WHATS_NEW" --notify
    [ "$status" -eq 0 ]
    grep -qx "Updated to Pulsar 26.12.1" "$NOTIFY_LOG"
    grep -qx "Snow, and pulsar snow for it." "$NOTIFY_LOG"
    grep -qx -- "--action=open=See what's new" "$NOTIFY_LOG"
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 26.12.1 ]
    [ ! -e "${BATS_TEST_TMPDIR}/opened" ]
    # the same release again: nothing
    : > "$NOTIFY_LOG"
    python3 "$WHATS_NEW" --notify
    [ ! -s "$NOTIFY_LOG" ]
    # the next one, clicked: the page opens
    sed -i 's/^## 26.11.1$/## 27.1.1/' "$PULSAR_RELEASE_NOTES"
    echo 27.1.1 > "$PULSAR_RELEASE_FILE"
    CLICK=1 python3 "$WHATS_NEW" --notify
    grep -qx "Updated to Pulsar 27.1.1" "$NOTIFY_LOG"
    [ "$(cat "${BATS_TEST_TMPDIR}/opened")" = "welcome --whats-new" ]
}

@test "what's new: a rollback says nothing, and neither does rolling forward again" {
    news_env
    python3 "$WHATS_NEW" --notify
    grep -qx "Updated to Pulsar 26.12.1" "$NOTIFY_LOG"
    # greenboot or the user rolls back: 26.11.1 has notes, and is not news
    : > "$NOTIFY_LOG"
    echo 26.11.1 > "$PULSAR_RELEASE_FILE"
    python3 "$WHATS_NEW" --notify
    [ ! -s "$NOTIFY_LOG" ]
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 26.12.1 ]
    # forward again: 26.12.1 was told already
    echo 26.12.1 > "$PULSAR_RELEASE_FILE"
    python3 "$WHATS_NEW" --notify
    [ ! -s "$NOTIFY_LOG" ]
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 26.12.1 ]
}

@test "what's new: releases compare as numbers, 26.9.1 before 26.10.1" {
    news_env
    sed -i 's/^## 26.12.1$/## 26.10.1/; s/^## 26.11.1$/## 26.9.1/' "$PULSAR_RELEASE_NOTES"
    # the record as an older image left it: one line, the release last told
    mkdir -p "$XDG_STATE_HOME/pulsar-welcome"
    echo 26.9.1 > "$XDG_STATE_HOME/pulsar-welcome/release"
    echo 26.10.1 > "$PULSAR_RELEASE_FILE"
    python3 "$WHATS_NEW" --notify
    grep -qx "Updated to Pulsar 26.10.1" "$NOTIFY_LOG"
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 26.10.1 ]
    # and back to 26.9.1, which sorts after 26.10.1 as a string
    : > "$NOTIFY_LOG"
    echo 26.9.1 > "$PULSAR_RELEASE_FILE"
    python3 "$WHATS_NEW" --notify
    [ ! -s "$NOTIFY_LOG" ]
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 26.10.1 ]
}

@test "what's new: skipping a release, the one installed is told once" {
    news_env
    mkdir -p "$XDG_STATE_HOME/pulsar-welcome"
    echo 26.10.1 > "$XDG_STATE_HOME/pulsar-welcome/release"
    python3 "$WHATS_NEW" --notify
    [ "$(grep -cx "Updated to Pulsar 26.12.1" "$NOTIFY_LOG")" -eq 1 ]
    python3 "$WHATS_NEW" --notify
    [ "$(grep -cx "Updated to Pulsar 26.12.1" "$NOTIFY_LOG")" -eq 1 ]
}

@test "what's new: a new account gets the tour, not the notice; a release without notes says nothing" {
    news_env
    mkdir -p "$TS"; touch "$TS/welcome.pending"
    python3 "$WHATS_NEW" --notify
    [ ! -s "$NOTIFY_LOG" ]
    # recorded all the same: the next release is news
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 26.12.1 ]
    rm "$TS/welcome.pending"
    echo 99.1.1 > "$PULSAR_RELEASE_FILE"
    python3 "$WHATS_NEW" --notify
    [ ! -s "$NOTIFY_LOG" ]
    [ "$(cat "$XDG_STATE_HOME/pulsar-welcome/release")" = 99.1.1 ]
}

@test "what's new: the notes ship, the unit is enabled with the welcome, and the app grid has the page" {
    cf="${REPO}/Containerfile"
    grep -qx 'COPY docs/releases.md /usr/share/pulsar/releases.md' "$cf"
    grep -q '^COPY scripts/pulsar-theme .*scripts/pulsar_whats_new.py.* /usr/libexec/pulsar/$' "$cf"
    grep -q 'systemctl --global enable pulsar-whats-new.service' "$cf"
    grep -qx 'enable pulsar-whats-new.service' "${REPO}/system_files/usr/lib/systemd/user-preset/50-pulsar.preset"
    d="${REPO}/system_files/usr/share/applications/digital.arclight.Pulsar.Welcome.desktop"
    grep -qx 'Actions=whats-new;' "$d"
    grep -qx 'Exec=/usr/libexec/pulsar/pulsar-welcome --whats-new' "$d"
}
