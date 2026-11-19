"""What Pulsar's own GTK apps share: where the CLI is, running it in the
background, and how an agent session reads to a person.

Imported by pulsar-settings and pulsar-agents, which sit beside it in
/usr/libexec/pulsar/ (and in scripts/ in a checkout). Gio only, so a test
can import it without a display.
"""
import datetime
import json
import os
import pathlib
import re

from gi.repository import Gio, GLib

HERE = pathlib.Path(__file__).resolve().parent

# The CLI. From a checkout, the checkout's own.
PULSAR = os.environ.get("PULSAR_CLI") or (
    str(HERE.parent / "cli" / "pulsar") if (HERE.parent / "cli" / "pulsar").exists() else "/usr/bin/pulsar")

# what `pulsar agent list` calls them
AGENT_NAMES = {"claude": "Claude Code", "codex": "Codex CLI", "agy": "Antigravity CLI",
               "opencode": "opencode", "gemini": "Gemini CLI", "aider": "aider"}
TMUX_SOCKET = os.environ.get("PULSAR_AGENT_TMUX_SOCKET") or "pulsar-agents"


def run(argv, done, *data):
    """argv in the background; done(ok, output, *data) on the main loop."""
    try:
        proc = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_MERGE)
    except GLib.Error as e:
        done(False, e.message, *data)
        return

    def finished(p, res):
        try:
            _ok, out, _err = p.communicate_utf8_finish(res)
        except GLib.Error as e:
            out = e.message
        done(p.get_successful(), out or "", *data)
    proc.communicate_utf8_async(None, None, finished)


def parse(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def day(ts):
    """A timestamp as a date a person reads: "October 3"."""
    try:
        d = datetime.datetime.fromtimestamp(int(ts))
    except (TypeError, ValueError, OverflowError, OSError):
        return None
    return f"{d:%B} {d.day}"


def ago(seconds):
    """How long, the way a person says it: "4 min", "2 h 5 min", "3 days"."""
    m = max(0, int(seconds)) // 60
    if m < 60:
        return f"{m} min"
    if m < 24 * 60:
        return f"{m // 60} h {m % 60} min" if m % 60 else f"{m // 60} h"
    d = m // (24 * 60)
    return "1 day" if d == 1 else f"{d} days"


def tokens(n):
    """950, 12k, 273k, 3.3M"""
    n = int(n or 0)
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        return f"{int(n / 1000 + 0.5)}k"
    return f"{n / 1_000_000:.1f}M"


def home(path):
    h = os.path.expanduser("~")
    return "~" + path[len(h):] if path and (path == h or path.startswith(h + "/")) else (path or "")


def session_doing(s, now):
    """What a session is doing, in a few words."""
    if s.get("state") == "waiting":
        return "Needs you" if s.get("waiting_for") == "Notification" else "Waiting for you"
    if s.get("state") == "running":
        return f"Running for {ago(now - s['started'])}" if s.get("started") else "Running"
    return "Ended"


def session_subtitle(s, now):
    """One line under a session's name: who, and what it is doing."""
    who = AGENT_NAMES.get(s.get("agent"), s.get("agent") or "Started by hand")
    return f"{who} · {session_doing(s, now)}"


def session_rows(s):
    """(title, subtitle) for what a session's row shows when opened."""
    rows = []
    folder = home(s.get("dir"))
    if folder:
        if s.get("worktree_of"):
            folder += f" (worktree of {home(s['worktree_of'])}, branch {s['name']})"
        rows.append(("Folder", folder))
    u = s.get("usage")
    if u:
        rows.append(("Context", f"{tokens(u.get('context'))} tokens now" + (f" · {u['model']}" if u.get("model") else "")))
        req = f"{u.get('requests', 0)} requests"
        if u.get("subagent_requests"):
            req += f", and {u['subagent_requests']} by subagents"
        rows.append(("Tokens", f"{tokens(u.get('read'))} read ({tokens(u.get('read_cached'))} from the cache) · "
                               f"{tokens(u.get('written'))} written · {req}"))
    return rows


def forget_body(s):
    """The Forget dialog's text. Only a Claude Code session resumes its
    conversation on Start (`agent run` passes --resume), so only it loses that."""
    if s.get("agent") == "claude":
        body = "Start can no longer bring its conversation back, and its undo snapshots are deleted."
    else:
        body = "Its undo snapshots are deleted."
    if s.get("worktree_of"):
        body += " Its worktree is removed if it has no uncommitted changes. The branch is kept."
    return body


def forget_left(r):
    """(heading, body) for what `agent sessions --forget --json` left behind,
    or None when it all went."""
    if not isinstance(r, dict):
        return None
    name, folder = r.get("name", ""), home(r.get("dir"))
    said = []
    if r.get("worktree") == "kept":
        said.append(f"Its worktree {folder} is still there: git won't remove a worktree with uncommitted "
                    f"changes. In a terminal, git worktree remove {r.get('dir')} says why.")
    if r.get("snapshots") == "left":
        said.append(f"{folder} is gone, so its undo snapshots couldn't be deleted. If it was in a git repository, "
                    f"git for-each-ref refs/pulsar/undo/{name}/ there lists them.")
    if not said:
        return None
    heading = "Worktree kept" if r.get("worktree") == "kept" else "Undo snapshots kept"
    return heading, f"{name} is forgotten. " + " ".join(said)


def session_order(s):
    return ({"waiting": 0, "running": 1}.get(s.get("state"), 2), s.get("name", ""))


# what `pulsar agent run --tmux` takes as a session name
NAME_OK = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]*$")


def session_name_for(folder, taken):
    """A session name from a folder's name, not one in `taken`: "my app" in
    ~/code becomes my-app, then my-app-2."""
    base = re.sub(r"[^A-Za-z0-9_-]+", "-", os.path.basename(os.path.normpath(folder or "")) or "").strip("-")
    base = base.lstrip("-") or "session"
    name, n = base, 2
    while name in taken:
        name, n = f"{base}-{n}", n + 1
    return name


def run_argv(agent, name, folder, worktree=False, sandbox=None, title=None, prompt=None):
    """What starts a new session: `pulsar agent run` with --tmux and --new.
    sandbox: True, False, or None for this project's setting. A title is what
    the app shows; a prompt is the agent's first message, sent as it starts."""
    argv = [PULSAR, "agent", "run", agent]
    if sandbox is not None:
        argv.append("--sandbox" if sandbox else "--no-sandbox")
    argv += ["--tmux", name, "--new", "--dir", folder]
    if worktree:
        argv.append("--worktree")
    if title:
        argv += ["--title", title]
    if prompt:
        argv += ["--prompt", prompt]
    return argv


# ------------------------------------------------- the Agents app's view --
def slug_name(text, taken, words=4):
    """A session name from the first words of a prompt: "Fix the flaky login
    test!" becomes fix-the-flaky-login; never one in `taken`; "" if the text
    has no letters or digits."""
    parts = re.findall(r"[A-Za-z0-9]+", text or "")[:words]
    base = "-".join(parts).lower()[:32].strip("-")
    if not base:
        return ""
    name, n = base, 2
    while name in taken:
        name, n = f"{base}-{n}", n + 1
    return name


def title_from_prompt(text, limit=48):
    """What the sidebar calls a session started with this prompt: its first
    line, cut at a word to fit."""
    line = " ".join((text or "").strip().splitlines()[:1]).strip() if (text or "").strip() else ""
    line = " ".join(line.split())
    if len(line) <= limit:
        return line
    cut = line[:limit].rsplit(" ", 1)[0] if " " in line[:limit] else line[:limit]
    return cut.rstrip(" ,.;:") + "…"


def session_title(s):
    return s.get("title") or s.get("name", "")


def when(ts, now):
    """How long ago, the way the sidebar says it: "just now", "5 min ago",
    "3 h ago", "yesterday", "Nov 3"."""
    try:
        ts = int(ts)
    except (TypeError, ValueError):
        return None
    d = max(0, now - ts)
    if d < 60:
        return "just now"
    if d < 3600:
        return f"{d // 60} min ago"
    t = datetime.datetime.fromtimestamp(ts)
    n = datetime.datetime.fromtimestamp(now)
    if t.date() == n.date():
        return f"{d // 3600} h ago"
    if (n.date() - t.date()).days == 1:
        return "yesterday"
    return f"{t:%b} {t.day}"


def deleted_in(archived, now, days):
    """When `agent sessions --tidy` deletes an archived session: "deleted in
    6 days", "deleted tomorrow", "deleted today"."""
    left = days - (max(0, now - int(archived)) // 86400)
    if left <= 0:
        return "deleted today"
    return "deleted tomorrow" if left == 1 else f"deleted in {left} days"


def session_status(s, now):
    """The sidebar's line under a session's title."""
    st = s.get("state")
    if st == "waiting":
        word = "Needs you" if s.get("waiting_for") == "Notification" else "Your turn"
        w = when(s.get("last_active"), now)
        return f"{word} · {w}" if w and w != "just now" else word
    if st == "running":
        return f"Working · {ago(now - s['started'])}" if s.get("started") else "Working"
    w = when(s.get("last_active"), now)
    return f"Stopped · {w}" if w else "Stopped"


def session_project(s):
    """The project a session belongs to: its repository, else its folder."""
    return s.get("project") or s.get("worktree_of") or s.get("dir") or ""


def _rank(s):
    return {"waiting": 0, "running": 1}.get(s.get("state"), 2)


def project_groups(sessions):
    """[(project, [sessions])] for the sidebar: archived ones left out; the
    project with the latest activity first; in each, the ones that need you,
    then the working ones, then the rest by recent activity."""
    groups = {}
    for s in sessions:
        if s.get("archived"):
            continue
        groups.setdefault(session_project(s), []).append(s)

    def latest(s):
        return s.get("last_active") or s.get("started") or 0
    out = []
    for p, ss in groups.items():
        ss.sort(key=lambda s: (_rank(s), -latest(s), s.get("name", "")))
        out.append((p, ss))
    out.sort(key=lambda g: (min(_rank(s) for s in g[1]), -max(latest(s) for s in g[1]), g[0]))
    return out


def project_label(project, projects):
    """A project's heading: its folder's name, with the parent's when two
    projects share a name."""
    base = os.path.basename(project.rstrip("/")) or project or "No folder"
    same = [p for p in projects if os.path.basename(p.rstrip("/")) == os.path.basename(project.rstrip("/"))]
    if len(same) > 1:
        parent = os.path.basename(os.path.dirname(project.rstrip("/")))
        if parent:
            return f"{base} ({parent})"
    return base


def newly_unseen(before, after, looking_at):
    """Sessions that stopped or started waiting since the last look, other
    than the one on screen: their dot lights until opened."""
    out = set()
    for name, s in after.items():
        old = before.get(name)
        if old is None or name == looking_at:
            continue
        if s.get("state") != old.get("state") and s.get("state") in ("waiting", "ended"):
            out.add(name)
    return out


def resume_note(s):
    """The banner while a stopped session comes back; it names the
    conversation only when it may not be the one the session had."""
    agent = s.get("agent")
    if agent in ("codex", "agy") and not s.get("worktree_of") and not (agent == "agy" and s.get("conversation")):
        return "Resuming this folder's latest conversation"
    return "Resuming" if agent else "Starting"


def diff_line_ref(diff, index):
    """(path, line) for line `index` (0-based) of a unified diff: the file it
    is in and its line number on the new side (the old side for a removed
    line), or None for a header line."""
    lines = (diff or "").split("\n")
    if index < 0 or index >= len(lines):
        return None
    path, new, old = None, None, None
    for i, ln in enumerate(lines[:index + 1]):
        at = i == index
        if ln.startswith("diff --git "):
            path, new, old = None, None, None
            m = re.match(r"diff --git a/(.*) b/(.*)$", ln)
            if m:
                path = m.group(2)
            if at:
                return None
        elif ln.startswith("+++ "):
            if ln[4:] != "/dev/null":
                path = ln[6:] if ln.startswith("+++ b/") else ln[4:]
            if at:
                return None
        elif ln.startswith("--- "):
            if not path and ln[4:] != "/dev/null":
                path = ln[6:] if ln.startswith("--- a/") else ln[4:]
            if at:
                return None
        elif ln.startswith("@@"):
            m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)", ln)
            if m:
                old, new = int(m.group(1)), int(m.group(2))
            if at:
                return (path, new) if path and new is not None else None
        elif new is None:
            if at:
                return None
        elif ln.startswith("+"):
            if at:
                return (path, new)
            new += 1
        elif ln.startswith("-"):
            if at:
                return (path, old)
            old += 1
        elif ln.startswith("\\"):
            if at:
                return None
        else:
            if at:
                return (path, new)
            new += 1
            old += 1
    return None


def comment_line(path, line, text):
    """A comment on a diff line as the agent reads it: path:line: text, and
    a space to go on typing after."""
    return f"{path}:{line}: {' '.join(text.split())} "
