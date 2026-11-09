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

# qr CODE...: zbarimg finds these codes, or nothing (exit 4) with none or "".
# Its output as zbarimg 0.23 printed it on cherenkov 2026-11-09 for a picture
# of two codes (one a link) and one of a contact card: --raw, each code then a
# newline; --xml, a <symbol> each, its data in CDATA.
qr() {
    QR_DIR="${BATS_TEST_TMPDIR}/qr"
    rm -rf "$QR_DIR"; mkdir -p "$QR_DIR"
    local c n=0
    for c in "$@"; do
        [ -n "$c" ] || continue
        n=$((n + 1))
        printf '%s' "$c" > "${QR_DIR}/${n}"
    done
    export QR_DIR
    cat > "${STUB}/zbarimg" <<'SH'
#!/bin/bash
[ "$1" = --quiet ] || { echo "bad args: $*" >&2; exit 1; }
mode=$2
set -- "$QR_DIR"/*
[ -e "$1" ] || exit 4
case "$mode" in
    --raw) for f in "$@"; do cat "$f"; echo; done ;;
    --xml)
        printf "<barcodes xmlns='http://zbar.sourceforge.net/2008/barcode'>\n<source href='%s'>\n<index num='0'>\n" "$PULSAR_SCREEN_IMAGE"
        for f in "$@"; do
            printf "<symbol type='QR-Code' quality='1' orientation='UP'><polygon points='+25,+25 +25,+172 +174,+174 +172,+25'/><data><![CDATA[%s]]></data></symbol>\n" "$(cat "$f")"
        done
        printf '</index>\n</source>\n</barcodes>\n' ;;
esac
SH
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

@test "REGRESSION: screen qr: two codes are both copied, and neither is offered to open" {
    # --raw put them on two lines; the first one's "https:" made the whole
    # two-line text "a link", handed to xdg-open as one
    qr "https://evil.example/x" "https://getpulsar.dev/blog"
    run python3 "$SCREEN" qr
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(cat "$CLIP")" = $'https://evil.example/x\nhttps://getpulsar.dev/blog' ]
    run cat "$NOTIFY_LOG"
    [ "$output" = "$(printf '%s\n' --app-name=Pulsar --icon=edit-copy-symbolic "Copied 2 QR codes" \
        "https://evil.example/x https://getpulsar.dev/blog")" ]
}

@test "screen qr: a code of several lines is one code; a link with more after it is not offered" {
    qr $'BEGIN:VCARD\nN:Doe;John\nTEL:+15551234\nEND:VCARD'
    run python3 "$SCREEN" qr
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(cat "$CLIP")" = $'BEGIN:VCARD\nN:Doe;John\nTEL:+15551234\nEND:VCARD' ]
    grep -qx "Copied the QR code" "$NOTIFY_LOG"
    : > "$NOTIFY_LOG"
    qr $'https://getpulsar.dev/\nrm -rf ~'
    run python3 "$SCREEN" qr
    [ "$status" -eq 0 ] || fail "$output"
    grep -qx "Copied the QR code" "$NOTIFY_LOG"
    run grep -c -- "--action" "$NOTIFY_LOG"
    [ "$output" = 0 ]
}

@test "screen qr: only a plain http(s) link with a host is offered to open" {
    run python3 - "$SCREEN" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ps", sys.argv[1])
spec = importlib.util.spec_from_loader("ps", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
for c in ("https://getpulsar.dev/blog?a=1#b", "http://192.168.1.1/", "HTTPS://getpulsar.dev/",
          "https:///etc/passwd", "file:///etc/passwd", "javascript:alert(1)", "https://a.example/ b",
          "https://a.example/\tb", "https://a.example/\x1b[2J", "getpulsar.dev"):
    print(repr(m.safe_link(c)))
PY
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "'https://getpulsar.dev/blog?a=1#b'
'http://192.168.1.1/'
'HTTPS://getpulsar.dev/'
None
None
None
None
None
None
None" ]
}

@test "screen: closing the screenshot UI is silent; only a real failure is said" {
    # GNOME's portal answers 2, not 1, when the person presses Esc
    run python3 - "$SCREEN" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ps", sys.argv[1])
spec = importlib.util.spec_from_loader("ps", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sys.stderr = sys.stdout   # in order
for code, uri in ((1, None), (2, None), (0, "file:///home/u/Pictures/Screenshots/Screenshot%20From%20x.png"),
                  (0, None), (0, ""), (3, "file:///x.png")):
    try:
        print(code, repr(m.portal_result(code, uri)))
    except RuntimeError as e:
        print(code, "error:", e)
PY
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "1 None" ]
    [ "${lines[1]}" = "pulsar-screen: the portal answered 2 (closed, or failed)" ]
    [ "${lines[2]}" = "2 None" ]
    [ "${lines[3]}" = "0 '/home/u/Pictures/Screenshots/Screenshot From x.png'" ]
    [ "${lines[4]}" = "0 error: the screenshot portal did not return a picture" ]
    [ "${lines[5]}" = "0 error: the screenshot portal did not return a picture" ]
    [ "${lines[6]}" = "3 error: the screenshot portal did not return a picture" ]
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
    # the person's own layout switch, on Super+Print: Super+Space is free
    gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super>Print']"
    run python3 "$SHORTCUTS"
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(custom pulsar-menu binding)" = "'<Super>space'" ]
    [ "$(custom pulsar-menu command)" = "'/usr/libexec/pulsar/pulsar-menu'" ]
    gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "/pulsar-menu/"
    # Super+Print was the account's: not bound, not in the list
    ! gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "pulsar-screen-text" || false
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source)" = "['<Super>Print']" ]
    # the notification names only what was bound
    [ "$(cat "$NOTIFY_LOG")" = "--app-name=Pulsar
--icon=input-keyboard-symbolic
New keyboard shortcuts
Super+Space: Pulsar commands
Change them in Settings > Keyboard." ] || fail "$(cat "$NOTIFY_LOG")"
    run python3 "$SHORTCUTS" --list
    [[ "$output" == *"bound to <Super>space"* ]]
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
    local q=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$p', '$q']"
    # the person's own Super+Space: not taken from the layout switch, though
    # the switch alone could have been; and their Super+/ too
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$p" binding "'<SUPER>Space'"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$q" binding "'<super>slash'"
    python3 "$SHORTCUTS" >/dev/null
    ! gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings | grep -q "pulsar-menu" || false
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source)" = "['<Super>space', 'XF86Keyboard']" ]
    run python3 "$SHORTCUTS" --list
    [[ "$output" == *"not bound: <Super>space is taken (org.gnome.desktop.wm.keybindings switch-input-source; custom shortcut $p); <Super>slash is taken (custom shortcut $q)"* ]] || fail "$output"
    # the existing list is kept, the new one added after it
    [ "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" = \
      "['$p', '$q', '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-screen-text/']" ]
}

@test "shortcuts: one keyboard layout and GNOME's own switch: the menu takes Super+Space from it" {
    shortcuts_env
    gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(custom pulsar-menu binding)" = "'<Super>space'" ]
    # the switch keeps its other keys, and the way back is untouched
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source)" = "['XF86Keyboard']" ]
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source-backward)" = "['<Shift><Super>space', '<Shift>XF86Keyboard']" ]
    grep -qx "Super+Space: Pulsar commands (it was the keyboard-layout switch, which does nothing with one layout)" "$NOTIFY_LOG"
    run python3 "$SHORTCUTS" --list
    [[ "$output" == *"bound to <Super>space, taken from org.gnome.desktop.wm.keybindings switch-input-source"* ]] || fail "$output"
}

@test "shortcuts: two layouts, or a switch of the person's own, keep Super+Space; the menu gets Super+/" {
    shortcuts_env
    gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us'), ('xkb', 'de')]"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(custom pulsar-menu binding)" = "'<Super>slash'" ]
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source)" = "['<Super>space', 'XF86Keyboard']" ]
    grep -qx "Super+/: Pulsar commands" "$NOTIFY_LOG"
    # one layout, but the switch is theirs (Super+Space alone, no XF86Keyboard)
    rm -f "$XDG_STATE_HOME/pulsar/shortcuts" "${XDG_CONFIG_HOME}/glib-2.0/settings/keyfile"
    gsettings set org.gnome.desktop.wm.keybindings switch-input-source "['<Super>space']"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(custom pulsar-menu binding)" = "'<Super>slash'" ]
    [ "$(gsettings get org.gnome.desktop.wm.keybindings switch-input-source)" = "['<Super>space']" ]
}

@test "shortcuts: a binding already in the list is not listed twice" {
    shortcuts_env
    local p=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-menu/
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$p']"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" = \
      "['$p', '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/pulsar-screen-text/']" ]
    [ "$(custom pulsar-menu binding)" = "'<Super>space'" ]
}

@test "shortcuts: a new account gets the welcome, not a notification" {
    shortcuts_env
    mkdir -p "$XDG_STATE_HOME/pulsar-theme"
    touch "$XDG_STATE_HOME/pulsar-theme/welcome.pending"
    python3 "$SHORTCUTS" >/dev/null
    [ "$(custom pulsar-menu binding)" = "'<Super>space'" ]
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

@test "menu: the screen readers wait until the menu is off the screen, nothing else does" {
    # else GNOME's screenshot UI freezes a frame with the menu fading out over the text
    run menu '
print(",".join(it.key for it in m.base_items() if it.settle))
print(m.SETTLE_MS >= 150)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "screen-text,screen-qr" ]
    [ "${lines[1]}" = "True" ]
}

@test "menu: apps in GNOME's order, once each, without hidden ones or Pulsar's listed ones" {
    run menu '
groups = [["b.desktop", "digital.arclight.Pulsar.Settings.desktop", "hidden.desktop"],
          ["a.desktop", "b.desktop", "digital.arclight.Pulsar.Welcome.desktop",
           "digital.arclight.Pulsar.Menu.desktop", "digital.arclight.Pulsar.ThemePicker.desktop"],
          ["c.desktop", "d.desktop", "e.desktop", "f.desktop"]]
shown = lambda i: i != "hidden.desktop"
print(m.pick_apps(groups, shown))
print(m.pick_apps(groups, shown, limit=2))
f = m.Found("fire", "app:x", "Firefox", "", "Apps")
print(f.matches("fire"), f.matches("fir"), f.matches(""))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['b.desktop', 'a.desktop', 'digital.arclight.Pulsar.Welcome.desktop', 'c.desktop', 'd.desktop']" ]
    [ "${lines[1]}" = "['b.desktop', 'a.desktop']" ]
    [ "${lines[2]}" = "True False False" ]
}

@test "menu: the file index is asked for each word as a prefix, in words it cannot misread" {
    run menu '
for q in ("invoice", "bl4-fix", "  Pulsar  Menu ", "it'"'"'s \"x\" OR*", "a", "", "*-\"", "ab"):
    print(repr(m.file_terms(q)))
print(m.files_allowed(False, []), m.files_allowed(True, []),
      m.files_allowed(False, ["org.gnome.Nautilus.desktop"]), m.files_allowed(False, ["org.gnome.Calculator.desktop"]))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "'invoice*'" ]
    [ "${lines[1]}" = "'bl4* fix*'" ]
    [ "${lines[2]}" = "'pulsar* menu*'" ]
    [ "${lines[3]}" = "'it* s* x* or*'" ]
    [ "${lines[4]}" = "''" ]
    [ "${lines[5]}" = "''" ]
    [ "${lines[6]}" = "''" ]
    [ "${lines[7]}" = "'ab*'" ]
    [ "${lines[8]}" = "True False False True" ]
}

@test "menu: files: the name as typed, yours first, nearer and newer next, no Wine prefixes" {
    run menu '
H = "/home/u"
own = ["/home/u/Pictures", "/home/u/Downloads"]
rows = [
    ("/home/u/Faugus/game/drive_c/users/steamuser/Pictures/Screenshots", 9.0, "2026-11-05"),
    ("/home/u/opt/tool/docs/screenshots", 9.0, "2026-11-04"),
    ("/home/u/Pictures/Screenshots", 6.0, "2026-01-01"),
    ("/home/u/Pictures/Screenshots/Screenshot old.png", 6.0, "2026-10-01"),
    ("/home/u/Pictures/Screenshots/Screenshot new.png", 6.0, "2026-11-05"),
    ("/home/u/Pictures/Screenshots/Screenshot new.png", 6.0, "2026-11-05"),
    ("/home/u/Downloads/my screenshots.zip", 6.0, "2026-11-05"),
    ("/home/u/Downloads/Setup.exe", 9.9, "2026-11-05"),
]
for p in m.rank_files(rows, "screensh", H, own):
    print(p)
print("--")
print(m.rank_files(rows, "screensh", H, own, limit=2))
print(m.rank_files([("/home/u/a/notes", 1, "x"), ("/home/u/Downloads/x/y/notes.md", 1, "x"), ("/home/u/z/notes app", 1, "x"),
                    ("/home/u/notesy", 1, "x")], "notes", H, own))
print(m.where("/home/u/Downloads/x.png", H), m.where("/home/u/x", H), m.where("/home/user2/x", H), m.where("/srv/x", H))
print(m.nothing_found("  my wife left me ")[0])'
    [ "$status" -eq 0 ] || fail "$output"
    # yours first (Pictures before ~/opt), shallower first, then newer; no Setup (stemmed), no drive_c
    [ "${lines[0]}" = "/home/u/Pictures/Screenshots" ]
    [ "${lines[1]}" = "/home/u/Pictures/Screenshots/Screenshot new.png" ]
    [ "${lines[2]}" = "/home/u/Pictures/Screenshots/Screenshot old.png" ]
    [ "${lines[3]}" = "/home/u/opt/tool/docs/screenshots" ]
    [ "${lines[4]}" = "/home/u/Downloads/my screenshots.zip" ]
    [ "${lines[5]}" = "--" ]
    [ "${lines[6]}" = "['/home/u/Pictures/Screenshots', '/home/u/Pictures/Screenshots/Screenshot new.png']" ]
    # the name itself first, wherever it is; yours before nearer; then starts-with
    [ "${lines[7]}" = "['/home/u/Downloads/x/y/notes.md', '/home/u/a/notes', '/home/u/notesy', '/home/u/z/notes app']" ]
    [ "${lines[8]}" = "~/Downloads Home folder /home/user2 /srv" ]
    [ "${lines[9]}" = "Nothing matches “my wife left me”" ]
}

@test "menu: a long name slides at one pace, whatever its length, once the row is settled on" {
    run menu '
print(m.scrub_ms(25), m.scrub_ms(229), m.scrub_ms(700))
print(round(25 / m.scrub_ms(25), 3) == round(700 / m.scrub_ms(700), 3))
print(m.SCRUB_DELAY_MS >= 400, m.SCRUB_HOLD_MS >= 1000)'
    [ "$status" -eq 0 ] || fail "$output"
    # 110 px a second whatever the overflow: three letters over moves as fast as a line over
    [ "${lines[0]}" = "227 2082 6364" ]
    [ "${lines[1]}" = "True" ]
    # arrowing past a row does not set it moving; the end stays up long enough to read
    [ "${lines[2]}" = "True True" ]
}

@test "menu: arithmetic and conversions in the search, worked out without eval" {
    run menu '
for q in ("2^10", "3x4", "(1920*1080)/4", "1/3", "15% of 80", "80 + 15%", "80 - 25%",
          "5 mi in km", "100 f in c", "-40 c to f", "2 GiB in MB", "90 min in h",
          "255 in hex", "-10 in hex", "0xff", "1,000*3", "123456789012345/1"):
    print(q, "=", " | ".join(m.calc(q)))
for q in ("42", "-5", "theme", "box 3x4", "10/0", "9^9^9", "__import__(\"os\").getcwd()",
          "(1).__class__", "5 km in kg", "2.5 in hex", "sqrt()+1", "foo*2", "2^5000", "((9^999)^999)^999"):
    print(q, "=", m.calc(q))
it = m.CalcItem()
print(it.matches("2^10"), it.title, "|", it.subtitle, "|", it.argv, it.matches("theme"))'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "2^10 = 1024 | 1024"
        "3x4 = 12 | 12"
        "(1920*1080)/4 = 518400 | 518400"
        "1/3 = 0.333333333333 | 0.333333333333"
        "15% of 80 = 12 | 12"
        "80 + 15% = 92 | 92"
        "80 - 25% = 60 | 60"
        "5 mi in km = 8.04672 km | 8.04672"
        "100 f in c = 37.7777777778 °C | 37.7777777778"
        "-40 c to f = -40 °F | -40"
        "2 GiB in MB = 2147.483648 MB | 2147.483648"
        "90 min in h = 1.5 h | 1.5"
        "255 in hex = 0xff | 0xff"
        "-10 in hex = -0xa | -0xa"
        "0xff = 255 | 255"
        "1,000*3 = 3000 | 3000"
        "123456789012345/1 = 123456789012345 | 123456789012345"
        # a lone number is a search; words, nonsense and anything but arithmetic are not sums
        "42 = None"
        "-5 = None"
        "theme = None"
        "box 3x4 = None"
        "10/0 = None"
        "9^9^9 = None"
        "__import__(\"os\").getcwd() = None"
        "(1).__class__ = None"
        "5 km in kg = None"
        "2.5 in hex = None"
        "sqrt()+1 = None"
        "foo*2 = None"
        # too big to be worth working out
        "2^5000 = None"
        "((9^999)^999)^999 = None"
        "True = 1024 | Enter copies 1024 | ['wl-copy', '--', '1024'] False"
    )
    for i in "${!expected[@]}"; do
        [ "${lines[$i]}" = "${expected[$i]}" ] || fail "line $i: '${lines[$i]}' != '${expected[$i]}'"
    done
}

@test "menu: easter eggs answer whole phrases only, in any case, and run nothing" {
    run menu '
it = m.CalcItem()
for q in ("SOMEONE SET US UP THE BOMB", "my wife left me!", "rm -rf /", "  Make  it  SO. "):
    print(it.matches(q), it.title, "|", it.argv, "|", it.group, "|", it.icon)
for q in ("someone set us up", "my wife", "make", "bomb", "firefox"):
    print(q, m.egg(q))
print(it.matches("2+2"), it.title, it.group, it.icon)'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "True All your base are belong to Pulsar. | [] |  | face-smile-big-symbolic"
        "True Pulsar can roll back an update. Not that. | [] |  | face-smile-big-symbolic"
        "True Nice try. | [] |  | face-smile-big-symbolic"
        "True Engage. | [] |  | face-smile-big-symbolic"
        "someone set us up None"
        "my wife None"
        "make None"
        "bomb None"
        "firefox None"
        "True = 4 Math accessories-calculator-symbolic"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: date math, from a fixed today" {
    run menu '
import datetime
today = datetime.date(2026, 11, 5)
for q in ("in 90 days", "3 weeks ago", "2026-12-25 + 45 days", "today + 30 days", "dec 25 - 10 days",
          "6 months from dec 1", "1 month after jan 31", "2 weeks before 2027-01-01", "in 2 years",
          "days until dec 25", "days since mar 1", "days since dec 25", "2026-12-25 - 2026-11-05", "12/25/2026 + 1 week",
          "dec 25", "25 december 2026", "yesterday"):
    print(q, "=", " | ".join(m.date_calc(q, today)))
for q in ("2026-02-30", "theme", "12/25", "next theme", "update 26"):
    print(q, "=", m.date_calc(q, today))'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "in 90 days = Wednesday, February 3, 2027 | 2027-02-03"
        "3 weeks ago = Thursday, October 15, 2026 | 2026-10-15"
        "2026-12-25 + 45 days = Monday, February 8, 2027 | 2027-02-08"
        "today + 30 days = Saturday, December 5, 2026 | 2026-12-05"
        "dec 25 - 10 days = Tuesday, December 15, 2026 | 2026-12-15"
        "6 months from dec 1 = Tuesday, June 1, 2027 | 2027-06-01"
        # the month is shorter: its last day
        "1 month after jan 31 = Sunday, February 28, 2027 | 2027-02-28"
        "2 weeks before 2027-01-01 = Friday, December 18, 2026 | 2026-12-18"
        "in 2 years = Sunday, November 5, 2028 | 2028-11-05"
        # no year: the next one for "until", the last one for "since"
        "days until dec 25 = 50 days (Friday, December 25, 2026) | 50"
        "days since mar 1 = 249 days (Sunday, March 1, 2026) | 249"
        "days since dec 25 = 315 days (Thursday, December 25, 2025) | 315"
        "2026-12-25 - 2026-11-05 = 50 days | 50"
        "12/25/2026 + 1 week = Friday, January 1, 2027 | 2027-01-01"
        "dec 25 = Friday, December 25, 2026 · in 50 days | 2026-12-25"
        "25 december 2026 = Friday, December 25, 2026 · in 50 days | 2026-12-25"
        "yesterday = Wednesday, November 4, 2026 · 1 day ago | 2026-11-04"
        "2026-02-30 = None"
        "theme = None"
        # 12/25 alone is a sum
        "12/25 = None"
        "next theme = None"
        "update 26 = None"
    )
    for i in "${!expected[@]}"; do
        [ "${lines[$i]}" = "${expected[$i]}" ] || fail "line $i: '${lines[$i]}' != '${expected[$i]}'"
    done
}

@test "menu: currency at the ECB's rates, fetched only when asked, cached, and stale beats nothing" {
    local feed="${BATS_TEST_TMPDIR}/rates.json"
    echo '{"amount":1.0,"base":"EUR","date":"2026-11-05","rates":{"USD":1.1497,"GBP":0.83393,"JPY":177.85}}' > "$feed"
    export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache" PULSAR_RATES_URL="file://${feed}"
    run menu '
r = {"date": "2026-11-05", "rates": {"USD": 1.1497, "GBP": 0.83393, "JPY": 177.85}}
for q in ("100 usd in eur", "$100 to gbp", "€50 in usd", "100 usd in jpy", "100usd to eur", "$5*3 in eur"):
    print(q, "=", " | ".join(m.currency_convert(m.currency_parse(q), r)))
for q in ("5 mi in km", "100 xyz in eur", "100 usd eur", "$100 usd in eur"):
    print(q, "=", m.currency_parse(q))
# the row: asks for rates once, shows it is waiting, then the answer
it = m.CalcItem(); asked = []
it.want_rates = lambda: asked.append(1)
print(it.matches("100 usd in eur"), it.title, "|", it.subtitle, "|", it.argv, len(asked))
it.rates = m.load_rates(now=1000)
print(it.matches("100 usd in eur"), it.title, "|", it.subtitle)
it.rates, it.rates_failed = None, True
print(it.matches("100 usd in eur"), it.title, "|", it.subtitle)'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "100 usd in eur = 86.98 EUR | 86.98"
        "\$100 to gbp = 72.53 GBP | 72.53"
        "€50 in usd = 57.48 USD | 57.48"
        "100 usd in jpy = 15,469 JPY | 15469"
        "100usd to eur = 86.98 EUR | 86.98"
        "\$5*3 in eur = 13.05 EUR | 13.05"
        "5 mi in km = None"
        "100 xyz in eur = None"
        "100 usd eur = None"
        "\$100 usd in eur = None"
        "True = … | Getting the exchange rates | [] 1"
        "True = 86.98 EUR | ECB rate of 2026-11-05 · Enter copies 86.98"
        "True = ? | No exchange rates: offline, and none saved yet"
    )
    for i in "${!expected[@]}"; do
        [ "${lines[$i]}" = "${expected[$i]}" ] || fail "line $i: '${lines[$i]}' != '${expected[$i]}'"
    done
    # fetched once and cached; a fresh cache is used without fetching
    [ "$(jq -r .fetched "${XDG_CACHE_HOME}/pulsar/currency.json")" = 1000 ]
    # the next day's rates are out, but the cache is fresh: not fetched
    sed -i 's/2026-11-05/2026-11-06/' "$feed"
    run menu 'print(m.load_rates(now=1000 + 3600)["date"])'
    [ "$output" = "2026-11-05" ]
    # 13 hours on, it is stale: fetched
    run menu 'print(m.load_rates(now=1000 + 13 * 3600)["date"])'
    [ "$output" = "2026-11-06" ]
    # stale and offline: the old rates, not nothing
    rm "$feed"
    run menu 'print(m.load_rates(now=1000 + 30 * 3600)["date"])'
    [ "$output" = "2026-11-06" ]
    # nothing cached and offline: None
    rm "${XDG_CACHE_HOME}/pulsar/currency.json"
    run menu 'print(m.load_rates(now=1000))'
    [ "$output" = "None" ]
}

@test "menu: a hex number works anywhere in a sum; x between numbers still multiplies" {
    run menu '
for q in ("0x10", "0x10 + 1", "0x1f", "0x7fffffff", "2*0x10", "0XFF - 0x0f", "3 x 0x10",
          "3x4", "3 x 4", "10x4", "(2)x(3)"):
    print(q, "=", m.calc(q))'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "0x10 = ('16', '16')"
        "0x10 + 1 = ('17', '17')"
        "0x1f = ('31', '31')"
        "0x7fffffff = ('2147483647', '2147483647')"
        "2*0x10 = ('32', '32')"
        "0XFF - 0x0f = ('240', '240')"
        "3 x 0x10 = ('48', '48')"
        "3x4 = ('12', '12')"
        "3 x 4 = ('12', '12')"
        "10x4 = ('40', '40')"
        "(2)x(3) = ('6', '6')"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: % with a number after it is the remainder; with none, a percent" {
    run menu '
for q in ("10 % 3", "10%3", "17 % 5 + 1", "7.5 % 2", "10 % (2+1)", "10 % pi",
          "50%", "50% * 2", "(50%)*4", "15% of 80", "80 + 15%", "80 - 15%"):
    print(q, "=", m.calc(q))'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "10 % 3 = ('1', '1')"
        "10%3 = ('1', '1')"
        "17 % 5 + 1 = ('3', '3')"
        "7.5 % 2 = ('1.5', '1.5')"
        "10 % (2+1) = ('1', '1')"
        "10 % pi = ('0.575222039231', '0.575222039231')"
        "50% = ('0.5', '0.5')"
        "50% * 2 = ('1', '1')"
        "(50%)*4 = ('2', '2')"
        "15% of 80 = ('12', '12')"
        "80 + 15% = ('92', '92')"
        "80 - 15% = ('68', '68')"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: real answers only: a negative number to a fraction is no answer, and Enter copies nothing" {
    run menu '
for q in ("(-8)^(1/3)", "(-2)^0.5", "(-8)^2", "(-8)^(-1)", "2^0.5"):
    print(q, "=", m.calc(q))
it = m.CalcItem()
print(it.matches("(-8)^(1/3)"), it.argv)'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "(-8)^(1/3) = None"
        "(-2)^0.5 = None"
        "(-8)^2 = ('64', '64')"
        "(-8)^(-1) = ('-0.125', '-0.125')"
        "2^0.5 = ('1.41421356237', '1.41421356237')"
        "False []"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: round() takes a half away from zero, as a calculator does" {
    run menu '
for q in ("round(2.5)", "round(-2.5)", "round(0.5)", "round(3.5)", "round(1.4)", "round(-0.4)", "round(2.675)", "round(7)"):
    print(q, "=", m.calc(q)[0])'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "$(printf '%s\n' "round(2.5) = 3" "round(-2.5) = -3" "round(0.5) = 1" "round(3.5) = 4" \
        "round(1.4) = 1" "round(-0.4) = 0" "round(2.675) = 3" "round(7) = 7")" ] || fail "$output"
}

@test "menu: a date past the year 9999 is no answer, never an error that stops the search" {
    run menu '
import datetime
today = datetime.date(2026, 11, 5)
for q in ("in 9000 years", "in 99999999 days", "99999999 days ago", "12/25/9999 + 1 week",
          "in 7000 years", "12/25/9999 - 1 week"):
    print(q, "=", m.date_calc(q, today))
real = m.date_calc
m.date_calc = lambda q, t=None: real(q, today)
it = m.CalcItem()
print(it.matches("2+2"), it.argv)
print(it.matches("in 9000 years"), it.argv)
# whatever a parser raises, the row is no answer, and keeps no old one
def boom(*a):
    raise RuntimeError("boom")
print(it.matches("2+2"), it.argv)
m.date_calc = boom
print(it.matches("2+2"), it.argv)
m.date_calc, m.calc, m.currency_parse = (lambda q, t=None: real(q, today)), boom, boom
print(it.matches("2+2"), it.matches("100 usd in eur"), it.argv)'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "in 9000 years = None"
        "in 99999999 days = None"
        "99999999 days ago = None"
        "12/25/9999 + 1 week = None"
        "in 7000 years = ('Sunday, November 5, 9026', '9026-11-05')"
        "12/25/9999 - 1 week = ('Saturday, December 18, 9999', '9999-12-18')"
        "True ['wl-copy', '--', '4']"
        "False []"
        "True ['wl-copy', '--', '4']"
        "False []"
        "False False []"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: Feb 29 with no year is the next or last one there is" {
    run menu '
import datetime
D = datetime.date
for today, q in ((D(2028, 3, 1), "feb 29"), (D(2028, 3, 1), "days until feb 29"),
                 (D(2028, 1, 15), "days since feb 29"), (D(2026, 11, 5), "days until feb 29"),
                 (D(2026, 11, 5), "days since feb 29"), (D(2028, 2, 29), "days until feb 29"),
                 (D(2026, 11, 5), "feb 30"), (D(2026, 11, 5), "days until feb 30")):
    print(today, q, "=", m.date_calc(q, today))'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "2028-03-01 feb 29 = ('Sunday, February 29, 2032 · in 1,460 days', '2032-02-29')"
        "2028-03-01 days until feb 29 = ('1,460 days (Sunday, February 29, 2032)', '1460')"
        "2028-01-15 days since feb 29 = ('1,416 days (Thursday, February 29, 2024)', '1416')"
        "2026-11-05 days until feb 29 = ('481 days (Tuesday, February 29, 2028)', '481')"
        "2026-11-05 days since feb 29 = ('980 days (Thursday, February 29, 2024)', '980')"
        "2028-02-29 days until feb 29 = ('0 days (Tuesday, February 29, 2028)', '0')"
        "2026-11-05 feb 30 = None"
        "2026-11-05 days until feb 30 = None"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: only a month's name or short form makes a date, not a word that starts like one" {
    run menu '
import datetime
today = datetime.date(2026, 11, 5)
for q in ("octopath 2", "marvel 2", "jungle 3", "4 decks", "decks 4", "mayday 1", "augment 3", "days until marvel 2",
          "sept 5", "sept. 5", "september 5", "5 sept", "june 3", "4 jul.", "march 3 2027", "days until may 1"):
    print(q, "=", m.date_calc(q, today))'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "octopath 2 = None"
        "marvel 2 = None"
        "jungle 3 = None"
        "4 decks = None"
        "decks 4 = None"
        "mayday 1 = None"
        "augment 3 = None"
        "days until marvel 2 = None"
        "sept 5 = ('Sunday, September 5, 2027 · in 304 days', '2027-09-05')"
        "sept. 5 = ('Sunday, September 5, 2027 · in 304 days', '2027-09-05')"
        "september 5 = ('Sunday, September 5, 2027 · in 304 days', '2027-09-05')"
        "5 sept = ('Sunday, September 5, 2027 · in 304 days', '2027-09-05')"
        "june 3 = ('Thursday, June 3, 2027 · in 210 days', '2027-06-03')"
        "4 jul. = ('Sunday, July 4, 2027 · in 241 days', '2027-07-04')"
        "march 3 2027 = ('Wednesday, March 3, 2027 · in 118 days', '2027-03-03')"
        "days until may 1 = ('177 days (Saturday, May 1, 2027)', '177')"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: a currency the ECB's rates lack says so; BGN is not offered" {
    run menu '
print("BGN" in m.CURRENCIES, m.currency_parse("100 bgn in eur"))
it = m.CalcItem()
it.rates = {"date": "2026-11-05", "rates": {"USD": 1.1497}}
for q in ("100 usd in jpy", "¥100 in usd", "100 usd in eur"):
    print(it.matches(q), it.title, "|", it.subtitle, "|", it.argv)
# rates without the rates in them: no answer, not an error
it.rates = {"date": "2026-11-05"}
print(it.matches("100 usd in eur"), it.argv)'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "False None"
        "True = ? | No rate for JPY in the ECB's rates of 2026-11-05 | []"
        "True = ? | No rate for JPY in the ECB's rates of 2026-11-05 | []"
        "True = 86.98 EUR | ECB rate of 2026-11-05 · Enter copies 86.98 | ['wl-copy', '--', '86.98']"
        "False []"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: a cache that is not rates, or from the future, is stale; the row always hears back" {
    local feed="${BATS_TEST_TMPDIR}/rates.json" cache
    echo '{"amount":1.0,"base":"EUR","date":"2026-11-05","rates":{"USD":1.1497}}' > "$feed"
    export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache" PULSAR_RATES_URL="file://${feed}"
    cache="${XDG_CACHE_HOME}/pulsar/currency.json"
    mkdir -p "${XDG_CACHE_HOME}/pulsar"
    local bad=('[]' 'null' '"rates"' '{"fetched":"x"}' '{"fetched":1000,"date":"2026-11-01"}'
               '{"fetched":1000,"date":"2026-11-01","rates":[]}'
               '{"fetched":1000,"date":"2026-11-01","rates":{"USD":"x"}}'
               '{"fetched":1000,"date":"2026-11-01","rates":{"USD":0}}')
    local future='{"fetched":5000000,"date":"2026-11-01","rates":{"USD":1.1}}'
    local c
    for c in "${bad[@]}" "$future"; do
        echo "$c" > "$cache"
        run menu 'print(m.load_rates(now=1000)["date"])'
        [ "$output" = "2026-11-05" ] || fail "cache $c: $output"
    done
    # a feed that is not rates: the stale cache, not an error, and not cached
    for c in '[]' '{"date":"2026-11-06"}' '{"date":"2026-11-06","rates":{"USD":"x"}}'; do
        echo "$c" > "$feed"
        echo '{"fetched":1,"date":"2026-11-01","rates":{"USD":1.1}}' > "$cache"
        run menu 'print(m.load_rates(now=100000)["date"])'
        [ "$output" = "2026-11-01" ] || fail "feed $c: $output"
    done
    # offline: a bad cache is none at all; the future one is stale, and beats nothing
    rm "$feed"
    for c in "${bad[@]}"; do
        echo "$c" > "$cache"
        run menu 'print(m.load_rates(now=1000))'
        [ "$output" = "None" ] || fail "offline, cache $c: $output"
    done
    echo "$future" > "$cache"
    run menu 'print(m.load_rates(now=1000)["date"])'
    [ "$output" = "2026-11-01" ] || fail "$output"
    # whatever getting them raises, the window is told: None, and the row says so
    run menu '
sys.stderr = sys.stdout
got = []
m.load_rates = lambda: 1 / 0
m.fetch_then(got.append)
m.load_rates = lambda: {"date": "d", "rates": {}}
m.fetch_then(got.append)
print(got)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "$(printf '%s\n' "pulsar-menu: exchange rates: ZeroDivisionError('division by zero')" \
        "[None, {'date': 'd', 'rates': {}}]")" ] || fail "$output"
}

@test "menu: the same search again adds no app or file twice; other searches' rows go" {
    run menu '
F = m.Found
shown = [m.CalcItem(), F("fi", "app:fi", "Fi", "", "Apps"), F("fire", "app:ff", "Firefox", "", "Apps"),
         F("fire", "file:/h/fire.txt", "fire.txt", "", "Files")]
gone, new = m.found_changes(shown, "fire", [F("fire", "app:ff", "Firefox", "", "Apps"),
                                            F("fire", "app:x", "X", "", "Apps")])
print([i.key for i in gone], [i.key for i in new])
gone, new = m.found_changes(shown, "fire", [F("fire", "file:/h/fire.txt", "fire.txt", "", "Files")])
print([i.key for i in gone], [i.key for i in new])
gone, new = m.found_changes(shown, "fir", [F("fir", "app:ff", "Firefox", "", "Apps")])
print([i.key for i in gone], [i.key for i in new])'
    [ "$status" -eq 0 ] || fail "$output"
    expected=(
        "['app:fi'] ['app:x']"
        "['app:fi'] []"
        "['app:fi', 'app:ff', 'file:/h/fire.txt'] ['app:ff']"
    )
    [ "$output" = "$(printf '%s\n' "${expected[@]}")" ] || fail "$output"
}

@test "menu: a paste of thousands of characters is a search, not a sum, and raises nothing" {
    run menu '
import datetime
today = datetime.date(2026, 11, 5)
huge = "-" * 6000 + "1"
print(m.calc(huge), m.currency_parse(huge + " usd in eur"), m.date_calc("in " + "9" * 5000 + " days", today))
print(m.CalcItem().matches(huge + " usd in eur"))
# a long sum that fits is still worked out
print(m.calc("1+" * 99 + "1"), m.currency_parse("1+" * 90 + "1 usd in eur"))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "$(printf '%s\n' "None None None" "False" "('100', '100') (91, 'USD', 'EUR')")" ] || fail "$output"
}
