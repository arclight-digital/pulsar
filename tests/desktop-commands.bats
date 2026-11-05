#!/usr/bin/env bats
# The screen reader (pulsar-screen), the shortcuts it and the command menu
# are offered on (pulsar-shortcuts), and the menu's own logic (pulsar-menu).
# The portal's screenshot UI and the menu window need a desktop session; what
# is tested here is everything either side of them. tesseract and zbarimg are
# stubs: what they make of a real screenshot was checked by hand (see the
# commit), and is theirs to get right.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    SCREEN="${REPO}/scripts/pulsar-screen"
    SHORTCUTS="${REPO}/scripts/pulsar-shortcuts"
    MENU="${REPO}/scripts/pulsar-menu"
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export PATH="${STUB}:${PATH}"
    export NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log" CLIP="${BATS_TEST_TMPDIR}/clip"
    : > "$NOTIFY_LOG"
    # one argument a line, a blank line after each call
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "$NOTIFY_LOG"; echo >> "$NOTIFY_LOG"\n' > "${STUB}/notify-send"
    printf '#!/bin/sh\ncat > "$CLIP"\n' > "${STUB}/wl-copy"
    chmod +x "${STUB}/notify-send" "${STUB}/wl-copy"
    export PULSAR_SCREEN_IMAGE="${BATS_TEST_TMPDIR}/shot.png"
    : > "$PULSAR_SCREEN_IMAGE"
}

fail() { echo "$*" >&2; return 1; }

# tesseract prints $OCR as it would: paragraphs, then a form feed
ocr() {
    export OCR="$1"
    printf '#!/bin/sh\n[ "$2" = - ] && [ "$4" = eng ] || { echo "bad args: $*" >&2; exit 1; }\nprintf "\\n%%s\\n\\n\\f" "$OCR"\n' > "${STUB}/tesseract"
    chmod +x "${STUB}/tesseract"
}

# zbarimg finds $QR, or nothing (exit 4) when it is empty
qr() {
    export QR="$1"
    printf '#!/bin/sh\n[ -n "$QR" ] || exit 4\nprintf "%%s\\n" "$QR"\n' > "${STUB}/zbarimg"
    chmod +x "${STUB}/zbarimg"
}

@test "screen text: the text goes on the clipboard as read, and the notification says how much" {
    ocr $'git push origin release/26.11.1\nfatal: the remote end hung up'
    run python3 "$SCREEN" text
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(cat "$CLIP")" = $'git push origin release/26.11.1\nfatal: the remote end hung up' ]
    grep -qx "Copied 2 lines of text" "$NOTIFY_LOG"
    grep -qx "git push origin release/26.11.1 fatal: the remote end hung up" "$NOTIFY_LOG"
    # a file it did not make is never deleted
    [ -e "$PULSAR_SCREEN_IMAGE" ]
}

@test "screen text: a long text is shortened in the notification, never on the clipboard" {
    ocr "$(printf 'word %.0s' $(seq 1 60))"
    run python3 "$SCREEN" text
    [ "$status" -eq 0 ]
    [ "$(wc -c < "$CLIP")" -eq 299 ]
    grep -qx "Copied 1 line of text" "$NOTIFY_LOG"
    [ "$(grep -x 'word word.*…' "$NOTIFY_LOG" | wc -m)" -eq 121 ]
}

@test "screen text: nothing read means nothing copied, and it says so" {
    ocr ""
    run python3 "$SCREEN" text
    [ "$status" -eq 0 ]
    [ ! -e "$CLIP" ]
    grep -qx "No text found" "$NOTIFY_LOG"
}

@test "screen qr: a link is copied and offered to open; plain text is just copied" {
    qr "https://getpulsar.dev/blog"
    run python3 "$SCREEN" qr
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(cat "$CLIP")" = "https://getpulsar.dev/blog" ]
    grep -qx -- "--action=open=Open link" "$NOTIFY_LOG"
    grep -qx "Copied the QR code" "$NOTIFY_LOG"
    : > "$NOTIFY_LOG"
    qr "WIFI:S:home;T:WPA;P:hunter2;;"
    run python3 "$SCREEN" qr
    [ "$(cat "$CLIP")" = "WIFI:S:home;T:WPA;P:hunter2;;" ]
    ! grep -q -- "--action" "$NOTIFY_LOG" || false
    : > "$NOTIFY_LOG"; rm -f "$CLIP"
    qr ""
    run python3 "$SCREEN" qr
    [ "$status" -eq 0 ]
    [ ! -e "$CLIP" ]
    grep -qx "No QR code found" "$NOTIFY_LOG"
}

@test "screen: a missing reader is said in words, and a bad call is a usage error" {
    # a PATH with nothing on it but the stubs: no tesseract
    run env PATH="$STUB" "$(command -v python3)" "$SCREEN" text
    [ "$status" -eq 1 ]
    grep -qx "tesseract is not installed here." "$NOTIFY_LOG"
    run python3 "$SCREEN" ocr
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: pulsar screen text | qr"* ]]
}

@test "pulsar screen hands text|qr to the tool, and nothing else" {
    printf '#!/bin/sh\necho "tool $*"\n' > "${STUB}/tool"; chmod +x "${STUB}/tool"
    export PULSAR_SCREEN_TOOL="${STUB}/tool" PULSAR_MANIFEST="${BATS_TEST_TMPDIR}/m.json"
    echo '{}' > "$PULSAR_MANIFEST"
    run "${REPO}/cli/pulsar" screen qr
    [ "$output" = "tool qr" ]
    run "${REPO}/cli/pulsar" screen text extra
    [ "$status" -ne 0 ]
    run "${REPO}/cli/pulsar" screen ocr
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage: pulsar screen text | qr"* ]]
}

# ---------------------------------------------------------------------------
# pulsar-shortcuts, against real gsettings on a private keyfile store and
# the fixture's schemas (the GNOME keys it touches, cut down)
# ---------------------------------------------------------------------------
shortcuts_env() {
    command -v gsettings >/dev/null && command -v glib-compile-schemas >/dev/null \
        || skip "no gsettings / glib-compile-schemas here"
    export GSETTINGS_SCHEMA_DIR="${BATS_TEST_TMPDIR}/schemas"
    mkdir -p "$GSETTINGS_SCHEMA_DIR"
    cp "${REPO}"/tests/fixtures/shortcut-schemas/*.gschema.xml "$GSETTINGS_SCHEMA_DIR"/
    glib-compile-schemas "$GSETTINGS_SCHEMA_DIR"
    export GSETTINGS_BACKEND=keyfile
    KEYFILE="${XDG_CONFIG_HOME}/glib-2.0/settings/keyfile"
}

custom() { gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/$1/" "$2"; }

@test "shortcuts: a free chord is bound and named once; a taken one is left alone" {
    shortcuts_env
    gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super>Print']"
    run python3 "$SHORTCUTS"
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(custom pulsar-menu binding)" = "'<Super>slash'" ]
    [ "$(custom pulsar-menu command)" = "'/usr/libexec/pulsar/pulsar-menu'" ]
    gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "/pulsar-menu/"
    # Super+Print was the account's: not bound, not in the list
    ! gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "pulsar-screen-text" || false
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source)" = "['<Super>Print']" ]
    # the notification names only what was bound
    [ "$(cat "$NOTIFY_LOG")" = "--app-name=Pulsar
--icon=input-keyboard-symbolic
New keyboard shortcuts
Super+/: Pulsar commands
Change them in Settings > Keyboard." ] || fail "$(cat "$NOTIFY_LOG")"
    run python3 "$SHORTCUTS" --list
    [[ "$output" == *"bound to <Super>slash"* ]]
    [[ "$output" == *"<Super>Print is taken (org.gnome.desktop.wm.keybindings switch-input-source)"* ]]
}

@test "shortcuts: each is offered once; one the person removed or moved stays that way" {
    shortcuts_env
    python3 "$SHORTCUTS" >/dev/null
    [ "$(custom pulsar-screen-text binding)" = "'<Super>Print'" ]
    # moved one, removed the other from the list
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-screen-text/ binding "'<Ctrl><Super>t'"
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-screen-text/']"
    : > "$NOTIFY_LOG"
    run python3 "$SHORTCUTS"
    [ "$status" -eq 0 ]
    [ "$(custom pulsar-screen-text binding)" = "'<Ctrl><Super>t'" ]
    ! gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "pulsar-menu" || false
    [ ! -s "$NOTIFY_LOG" ]
}

@test "shortcuts: a chord taken by another custom shortcut counts, whatever its modifier spelling" {
    shortcuts_env
    local p=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$p']"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$p" binding "'<SUPER>Slash'"
    python3 "$SHORTCUTS" >/dev/null
    ! gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "pulsar-menu" || false
    run python3 "$SHORTCUTS" --list
    [[ "$output" == *"taken (custom shortcut $p)"* ]] || fail "$output"
    # the existing list is kept, the new one added after it
    [ "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" = \
      "['$p', '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-screen-text/']" ]
}

@test "shortcuts: a binding already in the list is not listed twice" {
    shortcuts_env
    local p=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-menu/
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$p']"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" = \
      "['$p', '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-screen-text/']" ]
    [ "$(custom pulsar-menu binding)" = "'<Super>slash'" ]
}

@test "shortcuts: a new account gets the welcome, not a notification" {
    shortcuts_env
    mkdir -p "$XDG_STATE_HOME/pulsar-theme"
    touch "$XDG_STATE_HOME/pulsar-theme/welcome.pending"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(custom pulsar-menu binding)" = "'<Super>slash'" ]
    [ ! -s "$NOTIFY_LOG" ]
}

# ---------------------------------------------------------------------------
# pulsar-menu: what it lists and runs (no window: that needs a session)
# ---------------------------------------------------------------------------
menu() {
    python3 - "$MENU" <<PY
import importlib.machinery, importlib.util, sys
path = sys.argv[1]; sys.argv = [path]
loader = importlib.machinery.SourceFileLoader("pm", path)
spec = importlib.util.spec_from_loader("pm", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
$1
PY
}

@test "menu: the search matches every word, in the title or what it is for" {
    run menu '
items = m.base_items()
for q in ("ocr", "qr", "theme", "check upd", "snapshot", "agent ses", "nothing like this"):
    print(q, "=", ",".join(it.key for it in items if it.matches(q)))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "ocr = screen-text" ]
    [ "${lines[1]}" = "qr = screen-qr" ]
    [ "${lines[2]}" = "theme = themes,theme-next" ]
    [ "${lines[3]}" = "check upd = updates" ]
    [ "${lines[4]}" = "snapshot = checkpoint" ]
    [ "${lines[5]}" = "agent ses = sessions" ]
    [ "${lines[6]}" = "nothing like this = " ]
}

@test "menu: live sessions, waiting first, open in a terminal; ended ones are not listed" {
    run env HOME=/home/u PULSAR_CLI=/usr/bin/pulsar bash -c "$(declare -f menu); MENU='$MENU' menu '
s = [{\"name\": \"b\", \"agent\": \"codex\", \"state\": \"running\", \"dir\": \"/home/u/b\"},
     {\"name\": \"z\", \"agent\": \"claude\", \"state\": \"waiting\", \"dir\": \"/home/u/p/.worktrees/z\"},
     {\"name\": \"c\", \"agent\": \"claude\", \"state\": \"ended\"},
     {\"name\": \"d\", \"agent\": None, \"state\": \"running\"}]
for it in m.session_items(s):
    print(it.title, \"|\", it.subtitle, \"|\", \" \".join(it.argv))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${#lines[@]}" -eq 2 ]
    # z is waiting, so before b
    [ "${lines[0]}" = "Open session “z” | Claude Code · Waiting for you · ~/p/.worktrees/z | ptyxis --new-window -- /usr/bin/pulsar agent run claude --tmux z" ]
    [ "${lines[1]}" = "Open session “b” | Codex CLI · Running · ~/b | ptyxis --new-window -- /usr/bin/pulsar agent run codex --tmux b" ]
}

@test "menu: what prints runs in a terminal that waits; a checkpoint asks for the password there" {
    run env PULSAR_CLI=/usr/bin/pulsar bash -c "$(declare -f menu); MENU='$MENU' menu '
items = {it.key: it for it in m.base_items()}
print(items[\"checkpoint\"].argv)
print(items[\"screen-text\"].argv)
print(m.agent_item(\"claude\").title)
print(m.accel_label(\"<Super>slash\"), m.accel_label(\"<Super>Print\"), m.accel_label(\"<ctrl><super>t\"))'"
    [ "$status" -eq 0 ] || fail "$output"
    [[ "${lines[0]}" == "['ptyxis', '--new-window', '--', 'bash', '-c', '\"\$@\"; echo; read -rsn1 -p \"Press any key to close this window.\"', 'pulsar-menu', 'sudo', '/usr/bin/pulsar', 'checkpoint']" ]] || fail "${lines[0]}"
    [ "${lines[1]}" = "['/usr/libexec/pulsar/pulsar-screen', 'text']" ]
    [ "${lines[2]}" = "Ask Claude Code about this machine" ]
    [ "${lines[3]}" = "Super+/ Super+Print Ctrl+Super+T" ]
}
