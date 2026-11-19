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
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10},"model_context_window":100},"rate_limits":null}}\n'
      printf '{"type":"event_msg","payload":{"type":"agent_message"}}\n'
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":96000},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":23.5,"window_minutes":300,"resets_at":5},"secondary":{"used_percent":41,"window_minutes":10080,"resets_at":9}}}}\n'
      printf '{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}\n'
      printf '{"type":"event_msg","payload":{"type":"agent_message","message":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}\n'; } \
        > "${h}/.codex/sessions/2026/11/18/rollout-a.jsonl"
    mkdir -p "${h}/zero/.codex/sessions/2026/11/18"
    { printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$d"
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0},"model_context_window":9},"rate_limits":null}}\n'; } \
        > "${h}/zero/.codex/sessions/2026/11/18/rollout-z.jsonl"
    printf '{"type":"session_meta","payload":{"cwd":"/elsewhere"}}\n{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":2}}}\n' \
        > "${h}/.codex/sessions/2026/11/17/rollout-b.jsonl"
    touch "${h}/.codex/sessions/2026/11/17/rollout-b.jsonl"
    run env HOME="$h" bash -c "$(declare -f gui); REPO='$REPO' gui '
m = g.session_meter({\"agent\": \"codex\", \"dir\": \"$d\", \"sandbox\": \"off\"})
print(m[\"context\"], m[\"window\"], round(m[\"percent\"]))
print([(l[\"label\"], l[\"percent\"], l[\"resets_at\"]) for l in m[\"limits\"]])
print(g._window_label(60), g._window_label(2880))
print(g.session_meter({\"agent\": \"codex\", \"dir\": \"/nowhere\", \"sandbox\": \"off\"}))
import os; os.environ[\"CODEX_HOME\"] = \"$h/zero/.codex\"
print(g.session_meter({\"agent\": \"codex\", \"dir\": \"$d\", \"sandbox\": \"off\"}))'"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "96000 272000 35" ]
    [ "${lines[1]}" = "[('5-hour', 23.5, 5), ('Weekly', 41.0, 9)]" ]
    [ "${lines[2]}" = "1-hour 2-day" ]
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
