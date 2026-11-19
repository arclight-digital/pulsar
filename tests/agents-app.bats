#!/usr/bin/env bats
# The Agents app (pulsar-agents) and the helpers it shares with Pulsar
# Settings (pulsar_gui.py). The window itself, its terminals and the diff
# view need a desktop; what is tested here is what it decides: the session
# name and the command a new session starts with, the terminal's colors,
# and how snapshots and diffs read. The window was checked by hand under a
# headless mutter with a stand-in CLI (see the commit).

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    APP="${REPO}/scripts/pulsar-agents"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"
}

fail() { echo "$*" >&2; return 1; }

# python with the app loaded as m
app() {
    python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); gi.require_version("Vte", "3.91"); gi.require_version("GtkSource", "5"); from gi.repository import Adw, Vte, GtkSource' 2>/dev/null \
        || skip "no PyGObject GTK 4 / libadwaita / VTE / GtkSourceView here"
    python3 - "$APP" <<PY
import importlib.machinery, importlib.util, sys
path = sys.argv[1]; sys.argv = [path]
loader = importlib.machinery.SourceFileLoader("pa", path)
spec = importlib.util.spec_from_loader("pa", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
$1
PY
}

@test "a new session's name comes from its folder, made a valid session name, and never one that is taken" {
    run app '
print(m.session_name_for("/home/u/code/my app", set()))
print(m.session_name_for("/home/u/code/my app/", {"my-app"}))
print(m.session_name_for("/home/u/code/my app", {"my-app", "my-app-2"}))
print(m.session_name_for("/home/u/-x.y", set()))
print(m.session_name_for("/", set()))
print(bool(m.NAME_OK.match("ok_1-a")), bool(m.NAME_OK.match("-no")), bool(m.NAME_OK.match("a b")), bool(m.NAME_OK.match("")))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = my-app ]
    [ "${lines[1]}" = my-app-2 ]
    [ "${lines[2]}" = my-app-3 ]
    [ "${lines[3]}" = x-y ]
    [ "${lines[4]}" = session ]
    [ "${lines[5]}" = "True False False False" ]
}

@test "a new session starts with agent run --tmux --new in its folder; worktree and sandbox only when asked" {
    run env PULSAR_CLI=/usr/bin/pulsar bash -c "$(declare -f app); APP='$APP' app '
print(\" \".join(m.run_argv(\"claude\", \"fix\", \"/home/u/p\")))
print(\" \".join(m.run_argv(\"agy\", \"fix\", \"/home/u/p\", worktree=True, sandbox=True)))
print(\" \".join(m.run_argv(\"codex\", \"fix\", \"/home/u/p\", sandbox=False)))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "/usr/bin/pulsar agent run claude --tmux fix --new --dir /home/u/p" ]
    [ "${lines[1]}" = "/usr/bin/pulsar agent run agy --sandbox --tmux fix --new --dir /home/u/p --worktree" ]
    [ "${lines[2]}" = "/usr/bin/pulsar agent run codex --no-sandbox --tmux fix --new --dir /home/u/p" ]
}

@test "the terminal takes the theme's Ptyxis palette, the variant that matches the desktop's style" {
    local pal="${BATS_TEST_TMPDIR}/t.palette"
    { printf '[Palette]\nName=T\n\n[Light]\nForeground=#111111\nBackground=#eeeeee\nCursor=#0000ff\n'
      for i in $(seq 0 15); do printf 'Color%d=#0000%02d\n' "$i" "$i"; done
      printf '\n[Dark]\nForeground=#eeeeee\nBackground=#111111\n'
      for i in $(seq 0 15); do printf 'Color%d=#ff00%02d\n' "$i" "$i"; done; } > "$pal"
    printf '[Palette]\nName=Only light\n\n[Light]\nForeground=#111111\nBackground=#eeeeee\n' > "${pal}.broken"
    run app "
fg, bg, cur, colors = m.terminal_palette('$pal', True)
print(fg, bg, cur, len(colors), colors[15])
fg, bg, cur, colors = m.terminal_palette('$pal', False)
print(fg, bg, cur, colors[1])
print(m.terminal_palette('${pal}.broken', True))
print(m.terminal_palette('${BATS_TEST_TMPDIR}/none', True))"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "#eeeeee #111111 None 16 #ff0015" ]
    [ "${lines[1]}" = "#111111 #eeeeee #0000ff #000001" ]
    [ "${lines[2]}" = None ]
    [ "${lines[3]}" = None ]
}

@test "snapshots read as the session's start or a restart; a diff's summary is git's last --stat line" {
    run app '
print(m.snapshot_title({"subject": "pulsar: work started 2026-11-18 16:31"}))
print(m.snapshot_title({"subject": "pulsar: work restarted 2026-11-18 17:06"}))
print(m.snapshot_title({"subject": "pulsar: started-by-hand restarted 2026-11-18 17:06"}))
print(m.snapshot_title({}))
print(m.diff_summary(" a.py | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n"))
print(m.diff_summary(""))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "Session started" ]
    [ "${lines[1]}" = "Session restarted" ]
    [ "${lines[2]}" = "Session restarted" ]
    [ "${lines[3]}" = "Snapshot" ]
    [ "${lines[4]}" = "1 file changed, 1 insertion(+), 1 deletion(-)" ]
    [ "${lines[5]}" = "No changes since the session started" ]
}

@test "the header says who, what it is doing, where, and for Claude how full its context is" {
    run env HOME=/home/u bash -c "$(declare -f app); APP='$APP' app '
now = 1_000_000
print(m.header_subtitle({\"agent\": \"claude\", \"state\": \"waiting\", \"waiting_for\": \"Notification\",
                         \"dir\": \"/home/u/p\", \"usage\": {\"context\": 142310}}, now))
print(m.header_subtitle({\"agent\": \"agy\", \"state\": \"running\", \"started\": now - 600, \"dir\": \"/srv/x\", \"usage\": None}, now))
print(m.header_subtitle({\"agent\": None, \"state\": \"ended\"}, now))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "Claude Code · Needs you · ~/p · 142k context" ]
    [ "${lines[1]}" = "Antigravity CLI · Running for 10 min · /srv/x" ]
    [ "${lines[2]}" = "Started by hand · Ended" ]
}

@test "the desktop entry starts the app from the image, under its own icon" {
    local d="${REPO}/system_files/usr/share/applications/digital.arclight.Pulsar.Agents.desktop"
    grep -qx 'Exec=/usr/libexec/pulsar/pulsar-agents' "$d"
    grep -qx 'Icon=digital.arclight.Pulsar.Agents' "$d"
    [ -f "${REPO}/system_files/usr/share/icons/hicolor/scalable/apps/digital.arclight.Pulsar.Agents.svg" ]
    grep -q 'scripts/pulsar-agents ' "${REPO}/Containerfile"
    grep -q 'scripts/pulsar_gui.py ' "${REPO}/Containerfile"
    if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$d"; fi
}
