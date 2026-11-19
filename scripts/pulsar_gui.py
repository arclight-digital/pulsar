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
TMUX_SOCKET = "pulsar-agents"


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


def run_argv(agent, name, folder, worktree=False, sandbox=None):
    """What starts a new session: `pulsar agent run` with --tmux and --new.
    sandbox: True, False, or None for this project's setting."""
    argv = [PULSAR, "agent", "run", agent]
    if sandbox is not None:
        argv.append("--sandbox" if sandbox else "--no-sandbox")
    argv += ["--tmux", name, "--new", "--dir", folder]
    if worktree:
        argv.append("--worktree")
    return argv
