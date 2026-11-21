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

@test "the header says who, what it is doing and where (the status bar has the context)" {
    need_gtk
    run env HOME=/home/u bash -c "$(declare -f app); APP='$APP' app '
now = 1_000_000
print(m.header_subtitle({\"agent\": \"claude\", \"state\": \"waiting\", \"waiting_for\": \"Notification\",
                         \"dir\": \"/home/u/p\", \"usage\": {\"context\": 142310}}, now))
print(m.header_subtitle({\"agent\": \"agy\", \"state\": \"running\", \"started\": now - 600, \"dir\": \"/srv/x\", \"usage\": None}, now))
print(m.header_subtitle({\"agent\": None, \"state\": \"ended\"}, now))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "Claude Code · Needs you · ~/p" ]
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

@test "the sidebar groups sessions by project, newest started first, archived ones left out; a turn moves nothing" {
    need_gtk
    run app '
now = 1_000_000
ss = [{"name": "b", "project": "/p/two", "state": "running", "started": now - 100, "last_active": now - 5},
      {"name": "a", "project": "/p/one", "state": "ended", "last_active": now - 50},
      {"name": "c", "project": "/p/one", "state": "waiting", "started": now - 300, "last_active": now - 2},
      {"name": "d", "worktree_of": "/p/two", "dir": "/p/two/.worktrees/d", "state": "ended", "last_active": now - 9},
      {"name": "e", "project": "/p/three", "state": "ended", "archived": now - 10, "last_active": now}]
def show():
    return " | ".join(p + " " + ",".join(s["name"] for s in g) for p, g in m.project_groups(ss))
print(show())
# turns end and start, activity ticks: the same order
before = show()
ss[0].update(state="waiting", last_active=now + 50); ss[2].update(state="running", last_active=now + 60)
print(show() == before)
# a session started again goes to the top of its project, and takes its project up
ss[2]["started"] = now + 70
print(show())
print(m.project_label("/a/x/app", ["/a/x/app", "/b/y/app"]), m.project_label("/a/x/web", ["/a/x/web"]))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "/p/two d,b | /p/one a,c" ] || fail "$output"
    [ "${lines[1]}" = "True" ] || fail "$output"
    [ "${lines[2]}" = "/p/one c,a | /p/two d,b" ] || fail "$output"
    [ "${lines[3]}" = "app (x) web" ] || fail "$output"
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
open(m.STATE_FILE, \"w\").write(\"[1]\"); print(sorted(m.load_state()))
open(m.STATE_FILE, \"w\").write(\"{\\\"shell_open\\\": 5}\"); print(m.load_state()[\"shell_open\"])
open(m.STATE_FILE, \"w\").write(\"{\\\"order\\\": [1]}\"); print(m.load_state()[\"order\"])'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['order', 'projects', 'recent', 'shell_open', 'unseen']" ] || fail "$output"
    [ "${lines[1]}" = "x ['x']" ]
    [ "${lines[2]}" = "['order', 'projects', 'recent', 'shell_open', 'unseen']" ] || fail "$output"
    # which sessions had their shell panel open: a list, or none
    [ "${lines[3]}" = "[]" ] || fail "$output"
    # the sidebar's order: a mapping, or none
    [ "${lines[4]}" = "{}" ] || fail "$output"
    [ -f "${BATS_TEST_TMPDIR}/st/pulsar/agents-app.json" ]
}

@test "an archived session says when it will be deleted" {
    need_gtk
    run app '
now = 10 * 86400
for a in (now, now - 86400, now - 5 * 86400 - 10, now - 6 * 86400, now - 7 * 86400, now - 30 * 86400):
    print(m.deleted_in(a, now, 7))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "deleted in 7 days" ]
    [ "${lines[1]}" = "deleted in 6 days" ]
    [ "${lines[2]}" = "deleted in 2 days" ]
    [ "${lines[3]}" = "deleted tomorrow" ]
    [ "${lines[4]}" = "deleted today" ]
    [ "${lines[5]}" = "deleted today" ]
    # kept for good: nothing to say
    run app 'print(repr(m.deleted_in(0, 10 * 86400, 0)))'
    [ "$output" = "''" ] || fail "$output"
}

@test "Preferences: how long archived sessions are kept is the app's own; anything else falls back to a week" {
    need_gtk
    run app '
class W: pass
w = W()
for v in (1, 30, 0, 5, "x", None):
    w.state = {"tidy_days": v} if v is not None else {}
    print(m.Agents.tidy_days(w))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(echo "$output" | paste -sd' ')" = "1 30 0 7 7 7" ] || fail "$output"
}

# python with pulsar_gui loaded as g (Gio only: runs where GTK isn't)
gui() {
    python3 -c 'import gi; from gi.repository import Gio' 2>/dev/null || skip "no PyGObject here"
    python3 - "${REPO}/scripts" <<PY
import sys; sys.path.insert(0, sys.argv[1]); import pulsar_gui as g
$1
PY
}

@test "meters: Claude's context against its model's window; a whole million reads 1M" {
    run gui '
print(g.context_window("claude-opus-5-5"), g.context_window("claude-fable-5-2"), g.context_window("claude-sonnet-4-6"),
      g.context_window("claude-sonnet-4-6[1m]"), g.context_window("gpt-5"))
m = g.session_meter({"agent": "claude", "usage": {"context": 142310, "model": "claude-opus-5-5"}})
print(m["context"], m["window"], round(m["percent"], 1))
print(g.session_meter({"agent": "claude", "usage": None}), g.session_meter({"agent": "claude", "usage": {"context": 0}}))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "1000000 1000000 200000 1000000 None" ]
    [ "${lines[1]}" = "142310 1000000 14.2" ]
    [ "${lines[2]}" = "None None" ]
}

@test "meters: Codex's last token_count gives the context, its window, and both limits by their length" {
    local h="${BATS_TEST_TMPDIR}/h" d="${BATS_TEST_TMPDIR}/proj"
    mkdir -p "${h}/.codex/sessions/2026/11/18" "${h}/.codex/sessions/2026/11/17" "$d"
    { printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$d"
      printf '{"type":"turn_context","payload":{"approval_policy":"untrusted","sandbox_policy":{"type":"read-only"}}}\n'
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10},"model_context_window":100},"rate_limits":null}}\n'
      printf '{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}\n'
      printf '{"type":"event_msg","payload":{"type":"agent_message"}}\n'
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":96000},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":23.5,"window_minutes":300,"resets_at":5},"secondary":{"used_percent":41,"window_minutes":10080,"resets_at":9}}}}\n'
      printf '{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}\n'
      printf '{"type":"event_msg","payload":{"type":"agent_message","message":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}\n'
      # a new turn under way, its settings changed twice, nothing counted yet: the newest settings
      printf '{"type":"turn_context","payload":{"approval_policy":"untrusted","sandbox_policy":{"type":"read-only"}}}\n'
      printf '{"type":"turn_context","payload":{"approval_policy":"on-request","sandbox_policy":{"type":"workspace-write"}}}\n'; } \
        > "${h}/.codex/sessions/2026/11/18/rollout-a.jsonl"
    mkdir -p "${h}/zero/.codex/sessions/2026/11/18"
    { printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$d"
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0},"model_context_window":9},"rate_limits":null}}\n'; } \
        > "${h}/zero/.codex/sessions/2026/11/18/rollout-z.jsonl"
    printf '{"type":"session_meta","payload":{"cwd":"/elsewhere"}}\n{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":2}}}\n' \
        > "${h}/.codex/sessions/2026/11/17/rollout-b.jsonl"
    touch "${h}/.codex/sessions/2026/11/17/rollout-b.jsonl"
    # the usual order: a turn's settings, then its count
    local d2="${BATS_TEST_TMPDIR}/proj2"; mkdir -p "$d2"
    { printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$d2"
      printf '{"type":"turn_context","payload":{"approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}}\n'
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":7},"model_context_window":70},"rate_limits":null}}\n'; } \
        > "${h}/.codex/sessions/2026/11/17/rollout-c.jsonl"
    run env HOME="$h" bash -c "$(declare -f gui); REPO='$REPO' gui '
m = g.session_meter({\"agent\": \"codex\", \"dir\": \"$d\", \"sandbox\": \"off\"})
print(m[\"context\"], m[\"window\"], round(m[\"percent\"]))
print([(l[\"label\"], l[\"percent\"], l[\"resets_at\"]) for l in m[\"limits\"]], m[\"mode\"])
print(g._window_label(60), g._window_label(2880), g.session_meter({\"agent\": \"codex\", \"dir\": \"$d2\", \"sandbox\": \"off\"})[\"mode\"])
print(g.session_meter({\"agent\": \"codex\", \"dir\": \"/nowhere\", \"sandbox\": \"off\"}))
import os; os.environ[\"CODEX_HOME\"] = \"$h/zero/.codex\"
print(g.session_meter({\"agent\": \"codex\", \"dir\": \"$d\", \"sandbox\": \"off\"}))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "96000 272000 35" ]
    [ "${lines[1]}" = "[('5-hour', 23.5, 5), ('Weekly', 41.0, 9)] {'approval': 'on-request', 'sandbox': 'workspace-write'}" ] || fail "$output"
    [ "${lines[2]}" = "1-hour 2-day {'approval': 'never', 'sandbox': 'danger-full-access'}" ] || fail "$output"
    [ "${lines[3]}" = None ]
    [ "${lines[4]}" = None ]
}

@test "meters: Antigravity's conversation database holds the tokens in context and the window, as protobuf" {
    local h="${BATS_TEST_TMPDIR}/h"
    mkdir -p "${h}/.gemini/antigravity-cli/conversations"
    run env HOME="$h" bash -c "$(declare -f gui); REPO='$REPO' gui '
import sqlite3, os
def vi(n):
    b = b\"\"
    while True:
        c = n & 0x7f; n >>= 7
        b += bytes([c | (0x80 if n else 0)])
        if not n: return b
def ld(f, b): return vi(f << 3 | 2) + vi(len(b)) + b
def iv(f, n): return vi(f << 3) + vi(n)
cw = iv(1, 402012) + iv(4, 512000)
blob = ld(1, iv(2, 7) + ld(9, iv(3, 1) + ld(10, cw)))
db = os.path.expanduser(\"~/.gemini/antigravity-cli/conversations/c1.db\")
c = sqlite3.connect(db); c.execute(\"create table gen_metadata (idx integer primary key, data blob)\")
c.execute(\"insert into gen_metadata values (1, ?)\", (ld(1, ld(9, ld(10, iv(1, 5) + iv(4, 10)))),))
c.execute(\"insert into gen_metadata values (2, ?)\", (blob,)); c.commit(); c.close()
print(g.pb_get(blob, 1, 9, 10) == cw, g.pb_fields(iv(1, 300) + ld(2, b\"hi\")))
m = g.session_meter({\"agent\": \"agy\", \"conversation\": \"c1\", \"sandbox\": \"off\"})
print(m[\"context\"], m[\"window\"], round(m[\"percent\"]))
print(g.session_meter({\"agent\": \"agy\", \"conversation\": \"nope\", \"sandbox\": \"off\"}), g.session_meter({\"agent\": \"agy\"}))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "True [(1, 300), (2, b'hi')]" ]
    [ "${lines[1]}" = "402012 512000 79" ]
    [ "${lines[2]}" = "None None" ]
}

@test "meters: opencode's last assistant message with tokens: input plus the cache, read and written" {
    local h="${BATS_TEST_TMPDIR}/h"
    mkdir -p "${h}/.local/share/opencode"
    run env HOME="$h" bash -c "$(declare -f gui); REPO='$REPO' gui '
import sqlite3, os, json
db = os.path.expanduser(\"~/.local/share/opencode/opencode.db\")
c = sqlite3.connect(db); c.execute(\"create table session_message (id text, session_id text, type text, data text)\")
rows = [(\"m1\", \"ses_a\", \"assistant\", {\"tokens\": {\"input\": 5, \"output\": 1, \"cache\": {\"read\": 0, \"write\": 0}}}),
        (\"m2\", \"ses_b\", \"assistant\", {\"tokens\": {\"input\": 999, \"output\": 1}}),
        (\"m3\", \"ses_a\", \"assistant\", {\"tokens\": {\"input\": 1200, \"output\": 300, \"cache\": {\"read\": 40000, \"write\": 800}}}),
        (\"m4\", \"ses_a\", \"user\", {\"text\": \"hi\"})]
c.executemany(\"insert into session_message values (?, ?, ?, ?)\", [(a, b, t, json.dumps(d)) for a, b, t, d in rows]); c.commit(); c.close()
m = g.session_meter({\"agent\": \"opencode\", \"conversation\": \"ses_a\", \"sandbox\": \"off\"})
print(m[\"context\"], m[\"window\"], m[\"percent\"])'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "42000 None None" ]
}

@test "meters: a sandboxed session's agent files are read from its sandbox home first" {
    run env PULSAR_SANDBOX_HOMES=/box HOME=/home/u bash -c "$(declare -f gui); REPO='$REPO' gui '
print([str(p) for p in g.agent_homes({\"agent\": \"codex\", \"sandbox\": \"on\"})])
print([str(p) for p in g.agent_homes({\"agent\": \"codex\", \"sandbox\": \"off\"})])
print(g.resets_in(1000 + 7500, 1000), g.resets_in(10, 1000))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['/box/codex', '/home/u']" ]
    [ "${lines[1]}" = "['/home/u', '/box/codex']" ]
    [ "${lines[2]}" = "resets in 2 h 5 min resets now" ]
}

@test "the status bar names Claude's model the way people say it, and a whole million as 1M" {
    need_gtk
    run app '
print(m.model_name("claude-opus-5-5"), "|", m.model_name("claude-fable-5-2"), "|", m.model_name("gpt-5.1-codex"), "|", m.model_name(None))
print(m.short_tokens(1_000_000), m.short_tokens(1_500_000), m.short_tokens(272000))
print(m.context_text({"context": 142310, "window": 1_000_000, "percent": 14.231}), "|", m.context_text({"context": 42000}))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "Opus 5.5 | Fable 5.2 | gpt-5.1-codex | " ]
    [ "${lines[1]}" = "1M 1.5M 272k" ]
    [ "${lines[2]}" = "142k of 1M · 14% | 42k" ]
}

@test "a session's icon comes from its name alone, and only from the reviewed list of shapes" {
    run gui '
a = g.session_icon("fix-the-flaky-login"); print(a == g.session_icon("fix-the-flaky-login"), a != g.session_icon("gui"))
seen = set()
for k in range(4000):
    o, i, t, h1, h2 = g.session_icon(f"s{k}")
    assert (o, i) in g.ICON_PAIRS, (o, i)
    assert 0 <= t < g.ICON_TURNS.get(i, 1), (i, t)
    assert 0 <= h1 < 360 and 60 <= (h2 - h1) % 360 <= 150, (h1, h2)
    seen.add((o, i))
print(len(seen) == len(g.ICON_PAIRS), len(g.ICON_PAIRS))
print(sorted(g.ICON_OUTLINES), sorted(g.ICON_INSIDES))
print([p for p in g.ICON_PAIRS if p[0] == "circle"])
print(g.session_icon("gui"))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "True True" ]
    [ "${lines[1]}" = "True 22" ]
    # the reviewed list: no triangle or octagon, nothing long and round-ended, no pair of dots
    [ "${lines[2]}" = "['circle', 'diamond', 'hexagon', 'squircle'] ['dot', 'grid', 'half', 'orbit', 'quarter', 'ring']" ]
    [ "${lines[3]}" = "[('circle', 'half'), ('circle', 'quarter'), ('circle', 'orbit'), ('circle', 'grid')]" ]
    # pinned: the same name keeps its icon across versions
    [ "${lines[4]}" = "('hexagon', 'orbit', 7, 108, 184)" ]
}

@test "disk: sizes read as Files says them; amber when tight, red when suspend won't fit" {
    run gui '
print([g.human_bytes(b) for b in (0, 999, 1536, 43459411968, 85094682624, 1_200_000_000_000, None)])
need = 17_094_934_528
print(g.disk_level(85e9, need), g.disk_level(30e9, need), g.disk_level(17e9, need), g.disk_level(4e9, None),
      g.disk_level(19e9, None), g.disk_level(21e9, None), g.disk_level(None, need))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['0 B', '999 B', '1.5 KB', '43 GB', '85 GB', '1.2 TB', '0 B']" ]
    [ "${lines[1]}" = "ok low critical critical low ok ok" ]
}

@test "other machines' sessions join the list renamed name@machine; their commands go through pulsar machine exec there" {
    run gui '
local = [{"name": "fix", "dir": "/p"}]
remote = {"machines": [{"name": "mag", "ok": True}],
          "sessions": [{"name": "fix", "machine": "mag", "dir": "/p", "title": None}, {"name": "x"}]}
m = g.merge_machine_sessions(local, remote)
print([(s["name"], s.get("real_name"), s.get("machine")) for s in m])
S = {s["name"]: s for s in m}
print(" ".join(g.agent_argv(S, "attach", "fix@mag")[1:]))
print(" ".join(g.agent_argv(S, "sessions", "--title", "fix@mag", "t")[1:]))
print(" ".join(g.agent_argv(S, "attach", "fix")[1:]))
print(g.session_title(S["fix@mag"]), g.merge_machine_sessions(local, None) == local)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "[('fix', None, None), ('fix@mag', 'fix', 'mag')]" ]
    [ "${lines[1]}" = "machine exec mag -- agent attach fix" ]
    [ "${lines[2]}" = "machine exec mag -- agent sessions --title fix t" ]
    [ "${lines[3]}" = "agent attach fix" ]
    [ "${lines[4]}" = "fix True" ]
}

@test "a project on another machine is its own group, headed with the machine's name" {
    run gui '
a = {"project": "/home/n/rl", "machine": "mag"}; b = {"project": "/home/n/rl"}
print(g.session_project(a), g.session_project(b), g.split_project("mag:/home/n/rl"), g.split_project("/x"), g.split_project("/srv/a:b"))
ps = ["mag:/home/n/rl", "/home/n/rl", "box:/srv/a/app", "box:/srv/b/app"]
print([g.project_label(p, ps) for p in ps])
print([p for p, _ in g.project_groups([a, b])])'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "mag:/home/n/rl /home/n/rl ('mag', '/home/n/rl') (None, '/x') (None, '/srv/a:b')" ]
    [ "${lines[1]}" = "['rl · mag', 'rl', 'app (a) · box', 'app (b) · box']" ]
    [ "${lines[2]}" = "['/home/n/rl', 'mag:/home/n/rl']" ] || [ "${lines[2]}" = "['mag:/home/n/rl', '/home/n/rl']" ]
}

@test "another machine's sessions are remembered as it last listed them, and shown, dimmed, while it doesn't answer" {
    run gui '
import json
remote = {"machines": [{"name": "talos", "ok": True}, {"name": "mag", "ok": False, "error": "No route to host"}],
          "sessions": [{"name": "train", "machine": "talos", "agent": "claude", "state": "running", "dir": "/h/rl",
                        "usage": {"context": 5}, "account": "n@work.example"}, {"name": "old", "machine": "talos", "archived": 7}]}
seen = g.remember_machines({"mag": {"at": 50, "sessions": [{"name": "fix", "agent": "codex", "dir": "/h/p"}]}}, remote, 100)
print(json.dumps(seen, sort_keys=True))
# talos answers again without its session: what it says now is what is kept
print(json.dumps(g.remember_machines(seen, {"machines": [{"name": "talos", "ok": True}], "sessions": []}, 200)["talos"]))
# a failed answer changes nothing
print(g.remember_machines(seen, None, 300) == seen)
out = g.merge_machine_sessions([{"name": "here"}], remote, seen, ["talos", "mag"])
print(json.dumps([[s["name"], s.get("state"), s.get("offline"), s.get("seen_at")] for s in out]))
# before the first answer: checking; a machine no longer set up: gone
out = g.merge_machine_sessions([], None, seen, ["mag"])
print(json.dumps([[s["name"], s.get("offline")] for s in out]))
print(g.session_status(out[0], 50 + 7200 + 10))
print(g.session_status(dict(out[0], offline="unreachable"), 50 + 7200 + 10))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = '{"mag": {"at": 50, "sessions": [{"agent": "codex", "dir": "/h/p", "name": "fix"}]}, "talos": {"at": 100, "sessions": [{"account": "n@work.example", "agent": "claude", "dir": "/h/rl", "last_active": null, "name": "train", "project": null, "sandbox": null, "started": null, "title": null, "usage": {"context": 5}, "worktree_of": null}]}}' ] || fail "${lines[0]}"
    [ "${lines[1]}" = '{"at": 200, "sessions": []}' ] || fail "${lines[1]}"
    [ "${lines[2]}" = True ]
    [ "${lines[3]}" = '[["here", null, null, null], ["train@talos", "running", null, null], ["old@talos", null, null, null], ["fix@mag", "offline", "unreachable", 50]]' ] || fail "${lines[3]}"
    [ "${lines[4]}" = '[["fix@mag", "checking"]]' ] || fail "${lines[4]}"
    [ "${lines[5]}" = "Checking mag…" ] || fail "${lines[5]}"
    [ "${lines[6]}" = "mag isn't answering · seen 2 h ago" ] || fail "${lines[6]}"
}

@test "a machine answering again isn't news: no unseen dot for what its sessions were doing meanwhile" {
    run gui '
before = {"a@m": {"state": "offline"}, "b": {"state": "running"}}
after = {"a@m": {"state": "waiting"}, "b": {"state": "waiting"}}
print(sorted(g.newly_unseen(before, after, None)))'
    [ "$output" = "['b']" ] || fail "$output"
}

@test "agent_argv: the first session named decides where a command runs; a title after it can't move it" {
    run gui '
ss = {"here": {"name": "here"}, "bar@m": {"name": "bar@m", "machine": "m", "real_name": "bar"}}
print(g.agent_argv(ss, "sessions", "--title", "here", "bar@m")[1:])
print(g.agent_argv(ss, "sessions", "--title", "bar@m", "here")[1:])
print(g.agent_argv(ss, "diff", "nobody")[1:])'
    [ "${lines[0]}" = "['agent', 'sessions', '--title', 'here', 'bar@m']" ] || fail "$output"
    [ "${lines[1]}" = "['machine', 'exec', 'm', '--', 'agent', 'sessions', '--title', 'bar', 'here']" ] || fail "$output"
    [ "${lines[2]}" = "['agent', 'diff', 'nobody']" ] || fail "$output"
}

@test "a new session's name avoids the repository's branches and worktrees, which --worktree would reuse" {
    local r="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "$r" && git -C "$r" init -q && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
    git -C "$r" branch fix-the-login; git -C "$r" branch other; mkdir -p "$r/.worktrees/old-one"
    mkdir -p "$r/sub"
    run gui "
r = '$r'
print(sorted(g.repo_names(r)))
print(sorted(g.repo_names(r + '/sub')))
print(g.slug_name('Fix the login', g.repo_names(r)))
print(sorted(g.repo_names('${BATS_TEST_TMPDIR}')))"
    [ "$status" -eq 0 ] || fail "$output"
    [[ "${lines[0]}" == "['fix-the-login', "*"'old-one', 'other']" ]] || fail "$output"
    [ "${lines[1]}" = "${lines[0]}" ] || fail "$output"
    [ "${lines[2]}" = fix-the-login-2 ] || fail "$output"
    [ "${lines[3]}" = "[]" ] || fail "$output"
}

@test "the app: typing while scrolled back leaves scrollback once; modifiers, Escape, Ctrl+C and arrows stay tmux's" {
    need_gtk
    run app '
sent = []
m.GLib.spawn_sync = lambda *a, **k: sent.append(a[1]) or (True, b"", b"", 0)
class T: scrolled = True
class W:
    def _pane(self, t): return "%3"
w, t = W(), T()
m.Agents._term_key(w, None, m.Gdk.KEY_Shift_L, 0, m.Gdk.ModifierType(0), t)
m.Agents._term_key(w, None, m.Gdk.KEY_Escape, 0, m.Gdk.ModifierType(0), t)
m.Agents._term_key(w, None, m.Gdk.KEY_Up, 0, m.Gdk.ModifierType(0), t)
m.Agents._term_key(w, None, m.Gdk.KEY_Page_Up, 0, m.Gdk.ModifierType(0), t)
m.Agents._term_key(w, None, m.Gdk.KEY_c, 0, m.Gdk.ModifierType.CONTROL_MASK, t)
print(len(sent), t.scrolled)
m.Agents._term_key(w, None, m.Gdk.KEY_a, 0, m.Gdk.ModifierType(0), t)
print(len(sent), t.scrolled, " ".join(sent[0][-3:]))
m.Agents._term_key(w, None, m.Gdk.KEY_b, 0, m.Gdk.ModifierType(0), t)
print(len(sent))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "0 True" ] || fail "$output"
    [ "${lines[1]}" = "1 False %3 #{pane_in_mode} send -X -t %3 cancel" ] || fail "$output"
    [ "${lines[2]}" = 1 ] || fail "$output"
}

@test "the launcher: a name typed before Start is the session's title, and its name is made from it" {
    need_gtk
    run app '
import os
m.Gtk.init()
m.run = lambda *a, **k: None
started = []
class W:
    sessions = {"login-fix": {}}
    state = {"projects": {}, "recent": []}
    def started(self, *a): started.append(a)
L = m.Launcher(W())
L.agents, L.default_agent = ["claude"], "claude"
L.agent.set_model(m.Gtk.StringList.new(["Claude Code"]))
L._set(os.environ["BATS_TEST_TMPDIR"])
L.buffer.set_text("Fix the flaky login test")
L.name.set_text("  Login   fix ")
L._go()
name, agent, title, argv = started[-1]
print(name, "|", title, "|", L.name.get_text() == "")
L.buffer.set_text("Fix the flaky login test")
L._go()
print(started[-1][0], "|", started[-1][2])'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "login-fix-2 | Login fix | True" ] || fail "$output"
    [ "${lines[1]}" = "fix-the-flaky-login | Fix the flaky login test" ] || fail "$output"
}

@test "the app: a renamed session's icon comes from its icon seed, else its name" {
    need_gtk
    run app '
m.Gtk.init()
i = m.SessionIcon("work", 34); a = i.icon
i.set_glyph("work:1a2b3c4d"); b = i.icon
print(a == m.session_icon("work"), b == m.session_icon("work:1a2b3c4d"), a != b)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "True True True" ] || fail "$output"
}


@test "the app's wheel: tmux's history when scrolled back or in a shell; the wheel itself, at the pointer, to an agent that asked for SGR mouse; else nothing; never arrow keys" {
    need_gtk
    run app '
w = m.wheel_command
print(w("%1", True, 3, True, True, True, (5, 7)))
print(w("%1", False, 2, True, False, False, (1, 1)))
print(repr(w("%1", True, 2, False, True, True, (5, 7))))
print(repr(w("%1", False, 1, False, True, True, (5, 7))))
print(w("%1", True, 3, False, False, False, (1, 1)))
print(w("%1", True, 3, False, False, True, (1, 1)), w("%1", False, 3, False, False, False, (1, 1)))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['send', '-X', '-t', '%1', '-N', '3', 'scroll-up']" ] || fail "$output"
    [ "${lines[1]}" = "['send', '-X', '-t', '%1', '-N', '2', 'scroll-down']" ] || fail "$output"
    [ "${lines[2]}" = "['send', '-t', '%1', '-l', '\x1b[<64;5;7M\x1b[<64;5;7M']" ] || fail "$output"
    [ "${lines[3]}" = "['send', '-t', '%1', '-l', '\x1b[<65;5;7M']" ] || fail "$output"
    [ "${lines[4]}" = "['copy-mode', '-e', '-t', '%1', ';', 'send', '-X', '-t', '%1', '-N', '3', 'scroll-up']" ] || fail "$output"
    [ "${lines[5]}" = "None None" ] || fail "$output"
}

@test "the app's wheel, on real tmux: a shell's history scrolls; an agent tracking the mouse gets SGR wheel reports at the pointer" {
    need_gtk
    command -v tmux >/dev/null || skip "needs tmux"
    export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
    local S="wheel-$$" got="${BATS_TEST_TMPDIR}/got"
    tmux -L "$S" -f /dev/null new-session -d -s sh -x 80 -y 20 "seq 1 300; sleep 60"
    # an agent that turns on mouse reports (1000 + SGR 1006) and keeps what it reads
    tmux -L "$S" new-session -d -s ag -x 80 -y 20 "python3 -c 'import os,sys,tty; tty.setraw(0); os.write(1, b\"\x1b[?1000h\x1b[?1006h\"); f=open(\"$got\",\"wb\")
while True:
    b=os.read(0,64)
    if not b: break
    f.write(b); f.flush()'"
    sleep 0.5
    run app '
import subprocess
S = "'"$S"'"
def tm(*a): return subprocess.run(["tmux", "-L", S, *a], capture_output=True, text=True).stdout.strip()
for target in ("=sh:", "=ag:"):
    pane = tm("display", "-p", "-t", target, "#{pane_id}")
    mode, mouse, sgr, alt = tm("display", "-p", "-t", pane, "#{pane_in_mode} #{mouse_any_flag} #{mouse_sgr_flag} #{alternate_on}").split()
    cmd = m.wheel_command(pane, True, 2, mode == "1", mouse == "1" and sgr == "1", alt == "1", (12, 4))
    subprocess.run(["tmux", "-L", S, *cmd])
import time; time.sleep(0.5)
print(tm("display", "-p", "-t", "=sh:", "#{pane_in_mode} #{scroll_position}"))'
    local got_bytes; got_bytes=$(cat -v "$got" 2>/dev/null)
    tmux -L "$S" kill-server
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[-1]}" = "1 2" ] || fail "the shell didn't scroll: $output"
    [ "$got_bytes" = '^[[<64;12;4M^[[<64;12;4M' ] || fail "the agent got '$got_bytes'"
}

# a stand-in window with the app's own shell panel methods
shell_win='
import os
m.Gtk.init()
spawned = []
m.Vte.Terminal.spawn_async = lambda self, flags, cwd, argv, env, *a: spawned.append((cwd, argv, env))
names = [n for n in vars(m.Agents) if n.startswith("_shell") or n in ("new_shell", "_all_shells", "_term_key", "_show_shell")]
W = type("W", (), {n: vars(m.Agents)[n] for n in names})
w = W()
w.shells, w.current, w.state, w.terms = {}, "a", {}, {}
w.shell_stack, w.shell_box, w.shell_dot = m.Gtk.Stack(), m.Gtk.Box(visible=False), m.Gtk.Box(visible=False)
w.shell_tabs = m.Adw.TabBar()
w.shell_toggle = m.Gtk.ToggleButton()
w._color = lambda t: None
d = os.environ["BATS_TEST_TMPDIR"]
os.environ["SHELL"] = "/bin/zsh"
'

@test "the shell panel: a login shell in the session's folder, or on its machine through pulsar machine shell, in tabs; outside the agents' tmux" {
    need_gtk
    run app "$shell_win"'
a = w._shell_start({"name": "a", "dir": d})
w._shell_start({"name": "a", "dir": d})
w._shell_start({"name": "b@talos", "machine": "talos", "dir": "/home/n/proj"})
w._shell_start({"name": "c", "dir": "/no/such/dir"})
for cwd, argv, env in spawned:
    print(cwd == d, cwd == os.path.expanduser("~"), argv[1:] if argv[0] == m.PULSAR else argv, "TMUX=" in env)
print({k: v.get_n_pages() for k, v in sorted(w.shells.items())}, a.page.get_title() == os.path.basename(d))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "True False ['/bin/zsh', '-l'] True" ] || fail "$output"
    [ "${lines[1]}" = "True False ['/bin/zsh', '-l'] True" ] || fail "$output"
    [ "${lines[2]}" = "False True ['machine', 'shell', 'talos', '--dir', '/home/n/proj'] True" ] || fail "$output"
    [ "${lines[3]}" = "False True ['/bin/zsh', '-l'] True" ] || fail "$output"
    [ "${lines[4]}" = "{'a': 2, 'b@talos': 1, 'c': 1} True" ] || fail "$output"
}

@test "the shell panel: a hidden shell that finishes a command or rings marks its tab and the button; looking clears it" {
    need_gtk
    run app "$shell_win"'
one = w._shell_start({"name": "a", "dir": d})
two = w._shell_start({"name": "a", "dir": d})
# panel hidden: a command finished in the first
w._shell_attention(one)
print(one.page.get_needs_attention(), w.shell_dot.get_visible())
# the panel shown, on the second tab: the first still marked, no dot on the button
w.shell_box.set_visible(True); w._shell_dot()
print(one.page.get_needs_attention(), w.shell_dot.get_visible())
# the tab you are looking at is never marked
w._shell_attention(two)
print(two.page.get_needs_attention())
# selecting the first clears it
w.shells["a"].set_selected_page(one.page)
print(one.page.get_needs_attention())'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "True True" ] || fail "$output"
    [ "${lines[1]}" = "True False" ] || fail "$output"
    [ "${lines[2]}" = "False" ] || fail "$output"
    [ "${lines[3]}" = "False" ] || fail "$output"
}

@test "the shell panel: exit closes its tab; the last one gone hides the panel; archiving ends a session's shells; Ctrl+\` and Ctrl+Shift+\`" {
    need_gtk
    run app "$shell_win"'
one = w._shell_start({"name": "a", "dir": d})
two = w._shell_start({"name": "a", "dir": d})
w.shell_toggle.set_active(True)
w._shell_exited(two)
print(w.shells["a"].get_n_pages(), two.dead, w.shell_toggle.get_active())
w._shell_exited(one)
print(w.shells["a"].get_n_pages(), w.shell_toggle.get_active())
w._shell_start({"name": "b", "dir": d})
w._shell_close("b"); w._shell_close("nope")
print(sorted(w.shells))
acts = []
w.activate_action = lambda name, p: acts.append(name)
class T: scrolled = False
for key, mods in ((m.Gdk.KEY_grave, m.Gdk.ModifierType.CONTROL_MASK),
                  (m.Gdk.KEY_asciitilde, m.Gdk.ModifierType.CONTROL_MASK | m.Gdk.ModifierType.SHIFT_MASK)):
    print(w._term_key(None, key, 0, mods, T()))
print(acts)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "1 True True" ] || fail "$output"
    [ "${lines[1]}" = "0 False" ] || fail "$output"
    [ "${lines[2]}" = "['a']" ] || fail "$output"
    [ "${lines[3]}" = "True" ] && [ "${lines[4]}" = "True" ] || fail "$output"
    [ "${lines[5]}" = "['win.shell', 'win.shell-new']" ] || fail "$output"
}

@test "a shell's tab is named for its folder: from bash's user@host:path title, else its folder; a program's own title as it is" {
    need_gtk
    run app '
import os
h = os.path.expanduser("~")
for title, cwd in (("proto@cherenkov:~/projects/arclight/pulsar", ""), ("proto@cherenkov:~", ""),
                   ("me@box:/tmp/x y/", ""), ("", h + "/code/site"), ("", h), ("", ""), ("vim notes.md", h + "/a")):
    print(repr(m.shell_tab_title(title, cwd)))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "'pulsar'
'~'
'x y'
'site'
'~'
'~'
'vim notes.md'" ] || fail "$output"
}

@test "the shell panel is shown or hidden per session, as you left it there; the session's own focus stands on switching" {
    need_gtk
    run app "$shell_win"'
w.sessions = {"a": {"name": "a", "dir": d}, "b": {"name": "b", "dir": d}}
w.shell_toggle.connect("toggled", lambda b: w._show_shell(b.get_active()))
# open in a
w.current = "a"; w._shell_sync(w.sessions["a"]); w.shell_toggle.set_active(True)
print(w.state["shell_open"], w.shell_box.get_visible())
# to b: hidden there
w.current = "b"; w._shell_sync(w.sessions["b"])
print(w.shell_toggle.get_active(), w.shell_box.get_visible(), w.state["shell_open"])
# back to a: shown again, its shell as it was
w.current = "a"; w._shell_sync(w.sessions["a"])
print(w.shell_toggle.get_active(), w.shell_box.get_visible(), w.shells["a"].get_n_pages())
# hidden in a: remembered
w.shell_toggle.set_active(False)
print(w.state["shell_open"])
# archiving forgets it
w.shell_toggle.set_active(True); w._shell_close("a")
print(w.state["shell_open"])'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['a'] True" ] || fail "$output"
    [ "${lines[1]}" = "False False ['a']" ] || fail "$output"
    [ "${lines[2]}" = "True True 1" ] || fail "$output"
    [ "${lines[3]}" = "[]" ] || fail "$output"
    [ "${lines[4]}" = "[]" ] || fail "$output"
}

@test "a hidden view of another machine's session stops counting toward its size there, marked once per change by its tag" {
    need_gtk
    run app '
m.Gtk.init()
calls = []
m.GLib.spawn_async = lambda argv, **k: calls.append(list(argv))
W = type("W", (), {"_sizes": m.Agents._sizes, "spawn": m.Agents.spawn, "_spawned": None})
w = W()
w.sessions = {"a": {"name": "a"}, "b@talos": {"name": "b@talos", "machine": "talos"}}
w.term_stack, w.terms = m.Gtk.Stack(), {}
w._client_tty = lambda t: "/dev/pts/9"
envs = {}
def term(name):
    t = m.Gtk.Box(); t.dead = False; t.name = name
    t.spawn_async = lambda flags, cwd, argv, env, *a: envs.__setitem__(name, env)
    t.grab_focus = lambda: None
    w.terms[name] = t; w.term_stack.add_child(t); w.term_stack.set_visible_child(t)
    return t
w._terminal = term
a = w.spawn("a", ["x"]); b = w.spawn("b@talos", ["y"])
print([e for e in envs["a"] if "TAG" in e], [e.split("=")[0] for e in envs["b@talos"] if "TAG" in e])
tag = b.view_tag
b.sized = True
w._sizes()                       # b on screen, as it started: nothing to say
print(len([c for c in calls if c[0] != "tmux"]))
w.term_stack.set_visible_child(a); w._sizes(); w._sizes()
remote = [c for c in calls if c[0] != "tmux"]
print(remote == [[m.PULSAR, "machine", "exec", "talos", "--", "agent", "sizes", "--view", tag, "hidden"]])
w.term_stack.set_visible_child(b); w._sizes()
print([c[-1] for c in calls if c[0] != "tmux"])
# the local one is still marked here, by its tty, never through a machine
print(all(c[:3] == ["tmux", "-L", m.TMUX_SOCKET] for c in calls if c[0] == "tmux"), len([c for c in calls if c[0] == "tmux"]) > 0)
c = m.VIEW_TAG; print(c != "" and all(ch.isalnum() for ch in c))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "[] ['PULSAR_AGENT_VIEW_TAG']" ] || fail "$output"
    [ "${lines[1]}" = "0" ] || fail "$output"
    [ "${lines[2]}" = "True" ] || fail "$output"
    [ "${lines[3]}" = "['hidden', 'shown']" ] || fail "$output"
    [ "${lines[4]}" = "True True" ] || fail "$output"
    [ "${lines[5]}" = "True" ] || fail "$output"
}

@test "a terminal's right-click menu: Copy once something is selected, Paste; Select All only in a shell, which keeps its own scrollback" {
    need_gtk
    run app '
m.Gtk.init()
ctx = m.GLib.MainContext.default()
def items(t):
    mm = t.get_context_menu_model()
    return [mm.get_item_attribute_value(i, "action").get_string() for i in range(mm.get_n_items())]
agent, shell = m.Vte.Terminal(), m.Vte.Terminal()
m.term_menu(agent); m.term_menu(shell, select_all=True)
win = m.Gtk.Window(child=shell); win.present()
while ctx.pending(): ctx.iteration(False)
print(items(agent), items(shell))
copy = shell.menu_actions.lookup_action("copy")
print(copy.get_enabled())
shell.feed(b"hello there\r\n")
while ctx.pending(): ctx.iteration(False)
shell.select_all()
while ctx.pending(): ctx.iteration(False)
print(copy.get_enabled())
seen = []
shell.copy_clipboard_format = lambda f: seen.append(f)
shell.paste_clipboard = lambda: seen.append("paste")
copy.activate(None); shell.menu_actions.lookup_action("paste").activate(None)
print(seen == [m.Vte.Format.TEXT, "paste"])
shell.unselect_all()
while ctx.pending(): ctx.iteration(False)
print(copy.get_enabled())
# the app'"'"'s own terminals have it: an agent'"'"'s, and a shell tab'"'"'s
W = type("W", (), {"_terminal": m.Agents._terminal, "_shell_start": m.Agents._shell_start, "_shell_view": m.Agents._shell_view})
w = W()
w.term_stack, w.terms, w.shells, w.shell_stack = m.Gtk.Stack(), {}, {}, m.Gtk.Stack()
for n in ("_now", "_color", "_exited", "_drew", "_term_key", "_term_scroll", "_shell_exited", "_shell_prop", "_shell_attention",
          "_shell_selected", "_shell_closing", "_shell_emptied", "_shell_moved"):
    setattr(w, n, lambda *a: None)
m.Vte.Terminal.spawn_async = lambda *a: None
print(items(w._terminal("a")), items(w._shell_start({"name": "a", "dir": "/"})))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['term.copy', 'term.paste'] ['term.copy', 'term.paste', 'term.select-all']" ] || fail "$output"
    [ "${lines[1]}" = "False" ] || fail "$output"
    [ "${lines[2]}" = "True" ] || fail "$output"
    [ "${lines[3]}" = "True" ] || fail "$output"
    [ "${lines[4]}" = "False" ] || fail "$output"
    [ "${lines[5]}" = "['term.copy', 'term.paste'] ['term.copy', 'term.paste', 'term.select-all']" ] || fail "$output"
}

@test "ports: the servers working in a folder, by their socket's port; not the agents' own, not elsewhere, not a worktree's in the project's" {
    local P="${BATS_TEST_TMPDIR}/proc"
    mkdir -p "${P}/net"
    # listening (0A) on 5173 (v4) and 4321 (v6), a connection (01) on 9999
    printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "${P}/net/tcp"
    printf '   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1\n' >> "${P}/net/tcp"
    printf '   1: 0100007F:270F 0100007F:9999 01 00000000:00000000 00:00000000 00000000  1000        0 333 1\n' >> "${P}/net/tcp"
    printf '   2: 0100007F:A7B3 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 444 1\n' >> "${P}/net/tcp"
    printf '   3: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 555 1\n' >> "${P}/net/tcp"
    printf '   4: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 666 1\n' >> "${P}/net/tcp"
    printf '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "${P}/net/tcp6"
    printf '   0: 00000000000000000000000001000000:10E1 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 222 1\n' >> "${P}/net/tcp6"
    local F="${BATS_TEST_TMPDIR}/proj"
    mkdir -p "${F}/web" "${F}/.worktrees/fix" "${BATS_TEST_TMPDIR}/elsewhere"
    # proc <pid> <comm> <cwd> <socket inode>...
    proc() {
        local d="${P}/$1"; mkdir -p "${d}/fd"; printf '%s\n' "$2" > "${d}/comm"; ln -s "$3" "${d}/cwd"
        local i=3 n; shift 3
        for n in "$@"; do ln -s "socket:[${n}]" "${d}/fd/${i}"; i=$((i + 1)); done
        ln -s /dev/null "${d}/fd/0"
    }
    proc 10 node "${F}/web" 111 333             # a dev server below the folder, and a connection
    proc 11 MainThread "$F" 222                 # another, in the folder itself, on v6
    proc 12 agy "$F" 444                        # the agent's own port
    proc 13 python3 "${F}/.worktrees/fix" 555   # a worktree session's server
    proc 14 node "${BATS_TEST_TMPDIR}/elsewhere" 555
    mkdir -p "${F}-two"
    proc 15 node "${F}-two" 666                 # a folder whose name only starts the same
    run gui "
P, F = '${P}', '${F}'
print(g.folder_ports(F, skip=[F + '/.worktrees'], proc=P))
print([p for p, _, _ in g.folder_ports(F, proc=P)])
print([p for p, _, _ in g.folder_ports(F + '/.worktrees/fix', proc=P)])
print(g.folder_ports(F + '-other', proc=P), g.folder_ports('', proc=P))"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "[(4321, 11, 'MainThread'), (5173, 10, 'node')]" ] || fail "$output"
    [ "${lines[1]}" = "[80, 4321, 5173]" ] || fail "$output"
    [ "${lines[2]}" = "[80]" ] || fail "$output"
    [ "${lines[3]}" = "[] []" ] || fail "$output"
}

@test "the status bar: the account the agent signs in with, the folder's ports, and the scratch folder once it holds something or the disk is tight" {
    need_gtk
    run app '
import types
m.Gtk.init()
m.run = lambda *a, **k: None
asked = []
m.folder_ports = lambda d, skip=(), proc="/proc": asked.append((d, list(skip))) or [(5173, 42, "node"), (4321, 43, "MainThread"), (8000, 44, "python3"), (9000, 45, "x")]
disk = types.SimpleNamespace(data={"free": 80_000_000_000, "suspend_need": 17_000_000_000},
                             session_bytes=lambda n: {"big": 3_100_000_000, "small": 5_000_000}.get(n, 0),
                             widget=m.Gtk.MenuButton())
win = types.SimpleNamespace(disk=disk, rail_toggle=m.Gtk.ToggleButton(), agent_argv=lambda *a: ["true"])
sb = m.StatusBar(win)
def kids(box):
    out, c = [], box.get_first_child()
    while c is not None:
        out.append(c); c = c.get_next_sibling()
    return out
now = 1_000_000
base = {"agent": "claude", "state": "running", "started": now - 60, "dir": "/p/app"}
sb.update(dict(base, name="big", account="me@work.example"), now)
print(sb.want[sb.account], sb.account_label.get_label(), sb.account.get_tooltip_text())
print([b.get_label() if isinstance(b, m.Gtk.Button) else b.get_label() for b in kids(sb.port_btns)], asked)
print(sb.want[sb.scratch], sb.scratch_label.get_label(), sb.scratch.has_css_class("low"))
# a little scratch, no account, a worktree session: hidden, and its own folder only
asked.clear()
sb.update(dict(base, name="small", worktree_of="/p/app", dir="/p/app/.worktrees/w"), now + 10)
print(sb.want[sb.account], sb.want[sb.scratch], asked)
# the disk gets tight: shown anyway, with what is free, in the warning color
disk.data = {"free": 12_000_000_000, "suspend_need": 17_000_000_000}
sb.update(dict(base, name="small"), now + 20)
print(sb.want[sb.scratch], sb.scratch_label.get_label(), sb.scratch.has_css_class("critical"))
# another machine: its account, said where; no ports or scratch from here
asked.clear(); disk.data = {"free": 80_000_000_000, "suspend_need": 0}
sb.update(dict(base, name="t@talos", machine="talos", account="n@work.example"), now + 30)
print(sb.account.get_tooltip_text(), sb.want[sb.ports], sb.want[sb.scratch], asked)
# sandboxed: its network is its own
sb.update(dict(base, name="sb", sandbox="on"), now + 40)
print(sb.want[sb.ports], asked)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "True me@work.example Claude Code is signed in as me@work.example" ] || fail "$output"
    [ "${lines[1]}" = "[':5173', ':4321', ':8000', '+1'] [('/p/app', ['/p/app/.worktrees'])]" ] || fail "$output"
    [ "${lines[2]}" = "True Scratch 3.1 GB False" ] || fail "$output"
    [ "${lines[3]}" = "False False [('/p/app/.worktrees/w', [])]" ] || fail "$output"
    [ "${lines[4]}" = "True Scratch 5.0 MB True" ] || fail "$output"
    [ "${lines[5]}" = "Claude Code is signed in as n@work.example on talos False False []" ] || fail "$output"
    [ "${lines[6]}" = "False []" ] || fail "$output"
}

@test "the status bar: what the agent may do without asking, in a few words; the warning color when it never asks" {
    need_gtk
    run app '
import types
m.Gtk.init()
m.run = lambda *a, **k: None
m.folder_ports = lambda *a, **k: []
print(m.mode_label("claude", "default")[:2], m.mode_label("claude", "bypassPermissions")[:2], m.mode_label("claude", "newMode")[:2])
print(m.mode_label("codex", {"approval": "on-request", "sandbox": "workspace-write"})[:2],
      m.mode_label("codex", {"approval": None, "sandbox": "danger-full-access"})[:2])
print(m.mode_label("agy", "auto"), m.mode_label("claude", None), m.mode_label("codex", {"approval": None, "sandbox": None}))
print(m.session_meter({"agent": "claude", "usage": {"context": 5, "model": "claude-opus-5-5", "mode": "plan"}})["mode"])
disk = types.SimpleNamespace(data={}, session_bytes=lambda n: 0, widget=m.Gtk.MenuButton())
sb = m.StatusBar(types.SimpleNamespace(disk=disk, rail_toggle=m.Gtk.ToggleButton(), agent_argv=lambda *a: ["true"]))
base = {"name": "a", "agent": "claude", "state": "running", "started": 1, "dir": "/p"}
sb.update(dict(base, meter={"context": 5, "window": 10, "mode": "acceptEdits"}), 100)
print(sb.want[sb.mode], sb.mode_label.get_label(), sb.mode.has_css_class("warn"), sb.mode.get_tooltip_text())
sb.update(dict(base, meter={"context": 5, "window": 10, "mode": "bypassPermissions"}), 200)
print(sb.mode_label.get_label(), sb.mode.has_css_class("warn"))
sb.update(dict(base, meter={"context": 5, "window": 10, "mode": "plan"}), 300)
print(sb.mode.has_css_class("warn"))
sb.update(dict(base, agent="agy", meter={"context": 5, "window": 10}), 400)
print(sb.want[sb.mode], sb.mode.get_visible())'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "('Asks first', False) ('Never asks', True) ('newMode', False)" ] || fail "$output"
    [ "${lines[1]}" = "('Asks if needed · project only', False) ('full access', True)" ] || fail "$output"
    [ "${lines[2]}" = "None None None" ] || fail "$output"
    [ "${lines[3]}" = "plan" ] || fail "$output"
    [ "${lines[4]}" = "True Edits without asking False Claude Code's permission mode: acceptEdits" ] || fail "$output"
    [ "${lines[5]}" = "Never asks True" ] || fail "$output"
    [ "${lines[6]}" = "False" ] || fail "$output"
    [ "${lines[7]}" = "False False" ] || fail "$output"
}

@test "the sidebar's order: groups and sessions where you put them; new ones on top; a session stays in its own group" {
    run gui '
now = 1000
ss = [{"name": "a1", "project": "/a", "started": now - 1}, {"name": "a2", "project": "/a", "started": now - 2},
      {"name": "a3", "project": "/a", "started": now - 3}, {"name": "b1", "project": "/b", "started": now - 10},
      {"name": "c1", "project": "/c", "started": now - 20}]
show = lambda order=None: " | ".join(p + " " + ",".join(s["name"] for s in g) for p, g in g.project_groups([dict(x) for x in ss], order))
print(show())
order = {"projects": ["/c", "/a", "/gone"], "sessions": {"/a": ["a3", "a1", "a2"]}}
print(show(order))
# a new session and a new project, not in the order yet: on top
ss.append({"name": "a4", "project": "/a", "started": now}); ss.append({"name": "d1", "project": "/d", "started": now})
print(show(order))
print(show({"projects": "junk", "sessions": ["junk"]}) == show())
print(g.moved(["x", "y", "z"], "z", step=-1), g.moved(["x", "y", "z"], "x", step=-1), g.moved(["x", "y", "z"], "x", step=9),
      g.moved(["x", "y", "z"], "z", before="x"), g.moved(["x", "y", "z"], "x", after="z"), g.moved(["x", "y"], "q", step=1))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "/a a1,a2,a3 | /b b1 | /c c1" ] || fail "$output"
    [ "${lines[1]}" = "/b b1 | /c c1 | /a a3,a1,a2" ] || fail "$output"
    [ "${lines[2]}" = "/d d1 | /b b1 | /c c1 | /a a4,a3,a1,a2" ] || fail "$output"
    [ "${lines[3]}" = "True" ] || fail "$output"
    [ "${lines[4]}" = "['x', 'z', 'y'] ['x', 'y', 'z'] ['y', 'z', 'x'] ['z', 'x', 'y'] ['y', 'z', 'x'] ['x', 'y']" ] || fail "$output"
}

@test "moving in the sidebar: a drop lands next to its own kind, a session only in its group; Alt+arrows in the list move it; the order is kept" {
    need_gtk
    run app '
import types
m.Gtk.init()
proj = {"a1": "/a", "a2": "/a", "a3": "/a", "b1": "/b"}
place = lambda *a: m.drop_place(*a, project_of=proj.get)
print(place("session", "a3", "session", "a1", True), place("session", "a3", "session", "a2", False))
print(place("session", "a3", "session", "b1", True), place("session", "a3", "session", "a3", True),
      place("session", "a3", "project", "/a", True), place("session", "a3", "project", "/b", True))
print(place("project", "/b", "project", "/a", True), place("project", "/b", "session", "a2", False),
      place("project", "/a", "session", "a2", True), place("bogus", "x", "project", "/a", True))
W = type("W", (), {n: vars(m.Agents)[n] for n in ("move_session", "move_group", "_groups", "_list_key")})
w = W()
w.sessions = {n: {"name": n, "project": p, "started": 100 - i} for i, (n, p) in enumerate(proj.items())}
w.state = {"order": {}}
saved = []
w._order_changed = lambda name=None, project=None: saved.append((name, project))
m.save_state = lambda d: None
w.move_session("a3", before="a1")
w.move_group("/b", step=-1)
w.move_session("b1", step=-1)                      # alone in its group: nothing to do
print(w.state["order"], saved)
print([(p, [s["name"] for s in g]) for p, g in w._groups()])
# the keys, on the row the keyboard is on
class S:
    def __init__(self, n): self.name = n
class P:
    def __init__(self, p): self.project = p
m.SessionRow, m.ProjectRow = S, P
focus = [S("a1")]
w.list = types.SimpleNamespace(get_focus_child=lambda: focus[0])
A, SH = m.Gdk.ModifierType.ALT_MASK, m.Gdk.ModifierType.SHIFT_MASK
print(w._list_key(None, m.Gdk.KEY_Up, 0, A), w._list_key(None, m.Gdk.KEY_Up, 0, 0), w._list_key(None, m.Gdk.KEY_Left, 0, A))
print([s["name"] for s in dict(w._groups())["/a"]])
w._list_key(None, m.Gdk.KEY_Up, 0, A | SH)             # its group, up
print(w.state["order"]["projects"], [s["name"] for s in dict(w._groups())["/a"]])
focus[0] = P("/a"); w._list_key(None, m.Gdk.KEY_Down, 0, A)  # a heading: its group, down again
print(w.state["order"]["projects"])'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "('session', 'a3', {'before': 'a1'}) ('session', 'a3', {'after': 'a2'})" ] || fail "$output"
    [ "${lines[1]}" = "None None ('session', 'a3', {'step': -10000}) None" ] || fail "$output"
    [ "${lines[2]}" = "('project', '/b', {'before': '/a'}) ('project', '/b', {'after': '/a'}) None None" ] || fail "$output"
    [ "${lines[3]}" = "{'sessions': {'/a': ['a3', 'a1', 'a2']}, 'projects': ['/b', '/a']} [('a3', None), (None, '/b')]" ] || fail "$output"
    [ "${lines[4]}" = "[('/b', ['b1']), ('/a', ['a3', 'a1', 'a2'])]" ] || fail "$output"
    [ "${lines[5]}" = "True False False" ] || fail "$output"
    [ "${lines[6]}" = "['a1', 'a3', 'a2']" ] || fail "$output"
    [ "${lines[7]}" = "['/a', '/b'] ['a1', 'a3', 'a2']" ] || fail "$output"
    [ "${lines[8]}" = "['/b', '/a']" ] || fail "$output"
}

@test "a dragged row opens a gap where it would land: next to a session, atop its group, or past a whole group; the drop goes there" {
    need_gtk
    run app '
m.Gtk.init()
class S(m.Gtk.ListBoxRow):
    def __init__(self, n): super().__init__(); self.name = n
m.SessionRow = S
names = vars(m.Agents)
W = type("W", (), {n: names[n] for n in ("_gap_index", "_rows_in_list", "_drop_gap", "_drop_done", "_project_of",
                                         "move_session", "move_group", "_groups")})
w = W()
proj = {"a1": "/a", "a2": "/a", "b1": "/b", "b2": "/b"}
w.sessions = {n: {"name": n, "project": p, "started": 100 - i} for i, (n, p) in enumerate(proj.items())}
w.state = {"order": {}}
w.list, w.gap, w._drop = m.Gtk.ListBox(), None, None
for r in (m.ProjectRow("/a", "a", False), S("a1"), S("a2"), m.ProjectRow("/b", "b", False), S("b1"), S("b2")):
    w.list.append(r)
moved = []
w._order_changed = lambda name=None, project=None: moved.append((name, project))
m.save_state = lambda d: None
show = lambda: " ".join("|" if isinstance(r, m.DropGap) else getattr(r, "name", None) or "#" + r.project[1:] for r in w._rows_in_list())
for place in (("session", "a2", {"before": "a1"}), ("session", "a1", {"after": "a2"}), ("session", "b2", {"step": -10000}),
              ("project", "/b", {"before": "/a"}), ("project", "/a", {"after": "/b"}), ("project", "/a", {"after": "/a"})):
    print(w._gap_index(place), end=",")
print()
w._drop = ("session", "a2", {"before": "a1"}); w._drop_gap(w._gap_index(w._drop)); print(show())
w._drop_gap(w._gap_index(("project", "/a", {"after": "/b"}))); print(show())
w._drop_gap(1); w._drop_gap(w._gap_index(("session", "b2", {"step": -10000}))); print(show())
w._drop_gap(None); print(show(), w._drop)
# the drop: where the gap said
w._drop = ("session", "a2", {"before": "a1"}); w._drop_gap(1)
print(w._drop_done("session\ta2", 0), show(), w.state["order"], moved)'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "1,3,4,0,6,3," ] || fail "$output"
    [ "${lines[1]}" = "#a | a1 a2 #b b1 b2" ] || fail "$output"
    [ "${lines[2]}" = "#a a1 a2 #b b1 b2 |" ] || fail "$output"
    [ "${lines[3]}" = "#a a1 a2 #b | b1 b2" ] || fail "$output"
    [ "${lines[4]}" = "#a a1 a2 #b b1 b2 None" ] || fail "$output"
    [ "${lines[5]}" = "True #a a1 a2 #b b1 b2 {'sessions': {'/a': ['a2', 'a1']}} [('a2', None)]" ] || fail "$output"
}

@test "the status bar holds what fits, each segment whole: the least needed give way first, and come back with room" {
    need_gtk
    run app '
import types
m.Gtk.init()
m.run = lambda *a, **k: None
m.folder_ports = lambda *a, **k: [(5173, 1, "node")]
disk = types.SimpleNamespace(data={"free": 80_000_000_000, "suspend_need": 0},
                             session_bytes=lambda n: 3_100_000_000, widget=m.Gtk.MenuButton())
sb = m.StatusBar(types.SimpleNamespace(disk=disk, rail_toggle=m.Gtk.ToggleButton(), agent_argv=lambda *a: ["true"]))
sb.update({"name": "a", "agent": "claude", "state": "running", "started": 1, "dir": "/p", "account": "someone@work.example",
           "meter": {"context": 5, "window": 10, "mode": "acceptEdits"}}, 100)
sb._branch(True, "fix-login-redirect\n", "a")
H = m.Gtk.Orientation.HORIZONTAL
segs = {"scratch": sb.scratch, "branch": sb.branch, "mode": sb.mode, "account": sb.account, "ports": sb.ports}
for g in segs.values(): g.set_visible(True)
full = sb.widget.measure(H, -1)[1]
wid = {n: g.measure(H, -1)[1] for n, g in segs.items()}
def at(width):
    sb.outer.get_width = lambda: width
    sb.widget.get_width = lambda: 0
    sb._slack = 0
    sb._fit_key = None
    sb._fit()
    return [n for n, g in segs.items() if g.get_visible()]
print(at(full + 50))
print(at(full - wid["scratch"]))
print(at(full - wid["scratch"] - wid["branch"]))
print(at(200))
print(at(full + 50))
# no ellipsis on what may be cut: whole or not at all
print(sb.account_label.get_ellipsize() == m.Pango.EllipsizeMode.NONE, sb.branch_label.get_ellipsize() == m.Pango.EllipsizeMode.NONE)
# a low disk: its scratch folder is the last to go
disk.data = {"free": 2_000_000_000, "suspend_need": 17_000_000_000}
sb.update({"name": "a", "agent": "claude", "state": "running", "started": 1, "dir": "/p", "account": "someone@work.example",
           "meter": {"context": 5, "window": 10, "mode": "acceptEdits"}}, 200)
print([g is sb.scratch for g in sb._optional()][-1], sb.scratch_label.get_label())'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "['scratch', 'branch', 'mode', 'account', 'ports']" ] || fail "$output"
    [ "${lines[1]}" = "['branch', 'mode', 'account', 'ports']" ] || fail "$output"
    [ "${lines[2]}" = "['mode', 'account', 'ports']" ] || fail "$output"
    [ "${lines[3]}" = "[]" ] || fail "$output"
    [ "${lines[4]}" = "['scratch', 'branch', 'mode', 'account', 'ports']" ] || fail "$output"
    [ "${lines[5]}" = "True True" ] || fail "$output"
    [ "${lines[6]}" = "True Scratch 3.1 GB" ] || fail "$output"
}

@test "a row's classes are touched only when its state changes, so the pulse isn't restarted by every poll" {
    need_gtk
    run app '
m.Gtk.init()
b = m.Gtk.Box(); changes = []
b.connect("notify::css-classes", lambda *a: changes.append(1))
for on in (True, True, True, False, False, True):
    m.set_class(b, "needs", on)
print(len(changes), b.has_css_class("needs"))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "3 True" ] || fail "$output"
}
