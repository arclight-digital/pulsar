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

# skip where the app can't load (the builder has no GTK); called in the
# test itself, since skip inside `run` or `bash -c` does not skip
need_gtk() {
    python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); gi.require_version("Vte", "3.91"); gi.require_version("GtkSource", "5"); from gi.repository import Adw, Vte, GtkSource' 2>/dev/null \
        || skip "no PyGObject GTK 4 / libadwaita / VTE / GtkSourceView here"
}

# python with the app loaded as m
app() {
    python3 - "$APP" <<PY
import importlib.machinery, importlib.util, sys
path = sys.argv[1]; sys.argv = [path]
loader = importlib.machinery.SourceFileLoader("pa", path)
spec = importlib.util.spec_from_loader("pa", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
$1
PY
}

@test "a new session's name comes from its folder, made a valid session name, and never one that is taken" {
    need_gtk
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

@test "a new session starts with agent run --tmux --new in its folder; worktree, sandbox, title and prompt only when asked" {
    need_gtk
    run env PULSAR_CLI=/usr/bin/pulsar bash -c "$(declare -f app); APP='$APP' app '
print(\" \".join(m.run_argv(\"claude\", \"fix\", \"/home/u/p\")))
print(\" \".join(m.run_argv(\"agy\", \"fix\", \"/home/u/p\", worktree=True, sandbox=True)))
print(\" \".join(m.run_argv(\"codex\", \"fix\", \"/home/u/p\", sandbox=False)))
print(m.run_argv(\"claude\", \"fix\", \"/p\", title=\"Fix it\", prompt=\"fix the tests\")[-4:])'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "/usr/bin/pulsar agent run claude --tmux fix --new --dir /home/u/p" ]
    [ "${lines[1]}" = "/usr/bin/pulsar agent run agy --sandbox --tmux fix --new --dir /home/u/p --worktree" ]
    [ "${lines[2]}" = "/usr/bin/pulsar agent run codex --no-sandbox --tmux fix --new --dir /home/u/p" ]
    [ "${lines[3]}" = "['--title', 'Fix it', '--prompt', 'fix the tests']" ]
}

@test "the terminal takes the theme's Ptyxis palette, the variant that matches the desktop's style" {
    need_gtk
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
    need_gtk
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
    need_gtk
    run env HOME=/home/u bash -c "$(declare -f app); APP='$APP' app '
now = 1_000_000
print(m.header_subtitle({\"agent\": \"claude\", \"state\": \"waiting\", \"waiting_for\": \"Notification\",
                         \"dir\": \"/home/u/p\", \"usage\": {\"context\": 142310}}, now))
print(m.header_subtitle({\"agent\": \"agy\", \"state\": \"running\", \"started\": now - 600, \"dir\": \"/srv/x\", \"usage\": None}, now))
print(m.header_subtitle({\"agent\": None, \"state\": \"ended\"}, now))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "Claude Code · Needs you · ~/p · 142k context" ]
    [ "${lines[1]}" = "Antigravity CLI · Working · /srv/x" ]
    [ "${lines[2]}" = "Started by hand · Stopped" ]
}

@test "the desktop entry starts the app from the image, under its own icon" {
    local d="${REPO}/system_files/usr/share/applications/digital.arclight.Pulsar.Agents.desktop"
    grep -qx 'Exec=/usr/libexec/pulsar/pulsar-agents' "$d"
    grep -qx 'Icon=digital.arclight.Pulsar.Agents' "$d"
    local i="${REPO}/system_files/usr/share/icons/hicolor"
    [ -f "${i}/scalable/apps/digital.arclight.Pulsar.Agents.svg" ]
    [ -f "${i}/symbolic/apps/digital.arclight.Pulsar.Agents-symbolic.svg" ]
    [ -f "${i}/16x16/apps/digital.arclight.Pulsar.Agents.svg" ]
    [ -f "${i}/32x32/apps/digital.arclight.Pulsar.Agents.svg" ]
    grep -q 'scripts/pulsar-agents ' "${REPO}/Containerfile"
    grep -q 'scripts/pulsar_gui.py ' "${REPO}/Containerfile"
    if command -v desktop-file-validate >/dev/null; then desktop-file-validate "$d"; fi
}

@test "a session started with a prompt is named and titled from it; without one, from its folder" {
    need_gtk
    run app '
print(m.slug_name("Fix the flaky login test!", set()))
print(m.slug_name("Fix the flaky login test", {"fix-the-flaky-login"}))
print(repr(m.slug_name("!!", set())))
print(m.title_from_prompt("Fix the flaky login test in auth so that it passes on CI every single time"))
print(m.title_from_prompt("  short one\nsecond line"))
print(m.session_title({"name": "n", "title": None}), m.session_title({"name": "n", "title": "T"}))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = fix-the-flaky-login ]
    [ "${lines[1]}" = fix-the-flaky-login-2 ]
    [ "${lines[2]}" = "''" ]
    [ "${lines[3]}" = "Fix the flaky login test in auth so that it…" ]
    [ "${lines[4]}" = "short one" ]
    [ "${lines[5]}" = "n T" ]
}

@test "the sidebar groups sessions by project, needs-you first, archived ones left out" {
    need_gtk
    run app '
now = 1_000_000
ss = [{"name": "b", "project": "/p/two", "state": "running", "started": now - 100, "last_active": now - 5},
      {"name": "a", "project": "/p/one", "state": "ended", "last_active": now - 50},
      {"name": "c", "project": "/p/one", "state": "waiting", "last_active": now - 300},
      {"name": "d", "worktree_of": "/p/two", "dir": "/p/two/.worktrees/d", "state": "ended", "last_active": now - 9},
      {"name": "e", "project": "/p/three", "state": "ended", "archived": now - 10, "last_active": now}]
for p, g in m.project_groups(ss):
    print(p, ",".join(s["name"] for s in g))
print(m.project_label("/a/x/app", ["/a/x/app", "/b/y/app"]), m.project_label("/a/x/web", ["/a/x/web"]))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "/p/one c,a" ]
    [ "${lines[1]}" = "/p/two b,d" ]
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[2]}" = "app (x) web" ]
}

@test "a row says what a session is doing and since when; a stopped one says so only when it may come back on another conversation" {
    need_gtk
    run env TZ=UTC bash -c "$(declare -f app); APP='$APP' app '
now = 1_000_000
print(m.session_status({\"state\": \"waiting\", \"waiting_for\": \"Notification\", \"last_active\": now - 120}, now))
print(m.session_status({\"state\": \"waiting\", \"waiting_for\": \"Stop\", \"last_active\": now - 10}, now))
print(m.session_status({\"state\": \"running\", \"started\": now - 840}, now))
print(m.session_status({\"state\": \"ended\", \"last_active\": now - 90000}, now))
print(m.session_status({\"state\": \"ended\"}, now))
for s in ({\"agent\": \"claude\"}, {\"agent\": \"opencode\"}, {\"agent\": \"agy\", \"conversation\": \"u\"}, {\"agent\": \"agy\"},
          {\"agent\": \"codex\", \"worktree_of\": \"/r\"}, {\"agent\": \"codex\"}, {\"agent\": None}):
    print(m.resume_note(s))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "Needs you · 2 min ago" ]
    [ "${lines[1]}" = "Your turn" ]
    [ "${lines[2]}" = "Working · 14 min" ]
    [ "${lines[3]}" = "Stopped · yesterday" ]
    [ "${lines[4]}" = "Stopped" ]
    [ "${lines[5]}" = "Resuming" ]
    [ "${lines[6]}" = "Resuming" ]
    [ "${lines[7]}" = "Resuming" ]
    [ "${lines[8]}" = "Resuming this folder's latest conversation" ]
    [ "${lines[9]}" = "Resuming" ]
    [ "${lines[10]}" = "Resuming this folder's latest conversation" ]
    [ "${lines[11]}" = "Starting" ]
}

@test "a session lights up when it stops or waits while another one is on screen" {
    need_gtk
    run app '
before = {"a": {"state": "running"}, "b": {"state": "running"}, "c": {"state": "waiting"}, "d": {"state": "running"},
          "g": {"state": "waiting"}}
after = {"a": {"state": "waiting"}, "b": {"state": "running"}, "c": {"state": "waiting"}, "d": {"state": "ended"},
         "e": {"state": "waiting"}, "g": {"state": "running"}}
print(sorted(m.newly_unseen(before, after, None)))
print(sorted(m.newly_unseen(before, after, "a")))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['a', 'd']" ]
    [ "${lines[1]}" = "['d']" ]
}

@test "a comment on a diff line names the file and the line on its side, for the agent's own prompt" {
    need_gtk
    local d="${BATS_TEST_TMPDIR}/d.diff"
    printf '%s\n' 'diff --git a/x.py b/x.py' 'index 1..2 100644' '--- a/x.py' '+++ b/x.py' '@@ -3,4 +5,5 @@ def f():' \
        ' a' '-b' '+c' '+d' ' e' 'diff --git a/n.txt b/n.txt' 'new file mode 100644' '--- /dev/null' '+++ b/n.txt' \
        '@@ -0,0 +1,2 @@' '+one' '+two' > "$d"
    printf '%s\n' '--- /dev/null' '+++ b/z.txt' '@@ -0,0 +1 @@' '+z' > "${d}2"
    run app "
d = open('$d').read()
print([m.diff_line_ref(d, i) for i in range(17)])
print(m.diff_line_ref(d, 99), m.diff_line_ref(open('${d}2').read(), 3))
print(repr(m.comment_line('x.py', 4, '  why\n not  this? ')))"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "[None, None, None, None, ('x.py', 5), ('x.py', 5), ('x.py', 4), ('x.py', 6), ('x.py', 7), ('x.py', 8), None, None, None, None, ('n.txt', 1), ('n.txt', 1), ('n.txt', 2)]" ]
    [ "${lines[1]}" = "None ('z.txt', 1)" ]
    [ "${lines[2]}" = "'x.py:4: why not this? '" ]
}

@test "the changes summary counts files and lines, and says what it compares with when there are none" {
    need_gtk
    run app '
print(m.files_summary([{"path": "a", "added": 2, "removed": 1}, {"path": "b", "added": None, "removed": None}], False))
print(m.files_summary([{"path": "a", "added": 1, "removed": 0}], True))
print(m.files_summary([], False))
print(m.files_summary([], True))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "2 files · +2 −1" ]
    [ "${lines[1]}" = "1 file · +1 −0" ]
    [ "${lines[2]}" = "No changes since the session started" ]
    [ "${lines[3]}" = "Nothing uncommitted" ]
}

@test "the app remembers what it saw in its own state file, and starts clean from a bad one" {
    need_gtk
    run env XDG_STATE_HOME="${BATS_TEST_TMPDIR}/st" bash -c "$(declare -f app); APP='$APP' app '
d = m.load_state(); print(sorted(d))
d[\"unseen\"] = [\"x\"]; d[\"last\"] = \"x\"; m.save_state(d)
print(m.load_state()[\"last\"], m.load_state()[\"unseen\"])
open(m.STATE_FILE, \"w\").write(\"[1]\"); print(sorted(m.load_state()))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['projects', 'recent', 'unseen']" ]
    [ "${lines[1]}" = "x ['x']" ]
    [ "${lines[2]}" = "['projects', 'recent', 'unseen']" ]
    [ -f "${BATS_TEST_TMPDIR}/st/pulsar/agents-app.json" ]
}

@test "the agents' tmux has no status line, scrolls with the wheel and copies a selection to the desktop clipboard" {
    local c="${REPO}/system_files/usr/share/pulsar/agents-tmux.conf"
    grep -qx 'set -g status off' "$c"
    grep -qx 'set -g mouse on' "$c"
    grep -qx "set -s copy-command 'wl-copy'" "$c"
    # and tmux itself takes the file
    if command -v tmux >/dev/null; then
        local sock="agents-conf-test-$$"
        tmux -L "$sock" -f "$c" new-session -d -s t 'sleep 5'
        run tmux -L "$sock" show -gv status
        tmux -L "$sock" kill-server
        [ "$output" = off ]
    fi
}
