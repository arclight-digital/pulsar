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

@test "menu: a long name slides at a reading pace, only once the row is settled on" {
    run menu '
print(m.scrub_ms(10), m.scrub_ms(229), m.scrub_ms(700))
print(m.SCRUB_DELAY_MS >= 400, m.SCRUB_HOLD_MS >= 1000)'
    [ "$status" -eq 0 ] || fail "$output"
    # never a jump (500 ms at least), else 110 px a second
    [ "${lines[0]}" = "500 2081 6363" ]
    # arrowing past a row does not set it moving; the end stays up long enough to read
    [ "${lines[1]}" = "True True" ]
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
