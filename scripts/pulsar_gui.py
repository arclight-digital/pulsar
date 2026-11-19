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


# ------------------------------------------------------------- meters ----
# How full a session's context is, and the plan's limits where the agent
# writes them down. Read from each agent's own files, never from its
# status line (which would change the agent's screen in a terminal too):
#   Claude Code: the transcript's last request (pulsar agent sessions
#     --json, usage.context), against its model's window. No plan limits
#     on disk.
#   Codex: the session's rollout log, whose token_count events carry the
#     context, the model's window and both rate-limit windows.
#   Antigravity CLI: its conversation database, gen_metadata's
#     ContextWindowMetadata (tokens used, the window).
#   opencode: its database's last assistant message. No plan limits.
SANDBOX_HOMES = pathlib.Path(os.environ.get("PULSAR_SANDBOX_HOMES") or
                             os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"),
                                          "pulsar", "sandbox"))
_meter_cache = {}


def agent_homes(s):
    """Where a session's agent keeps its files: the sandbox's home first for
    a sandboxed session, then the real one."""
    real = pathlib.Path(os.path.expanduser("~"))
    box = SANDBOX_HOMES / (s.get("agent") or "")
    return [box, real] if s.get("sandbox") == "on" else [real, box]


def context_window(model):
    """Claude's window for a model id: 1M for the 5 family (Anthropic's
    default for them), 1M for a [1m] model, else 200K."""
    m = (model or "").lower()
    if "[1m]" in m or re.search(r"(opus|sonnet|haiku)-5|fable-5", m):
        return 1_000_000
    return 200_000 if m.startswith("claude") else None


def _varint(b, i):
    v = s = 0
    while True:
        c = b[i]
        i += 1
        v |= (c & 0x7f) << s
        s += 7
        if c < 0x80:
            return v, i


def pb_fields(b):
    """A protobuf message's fields, in order: [(number, int or bytes)]."""
    out, i = [], 0
    while i < len(b):
        key, i = _varint(b, i)
        f, w = key >> 3, key & 7
        if w == 0:
            v, i = _varint(b, i)
        elif w == 2:
            n, i = _varint(b, i)
            v, i = bytes(b[i:i + n]), i + n
        elif w == 1:
            v, i = bytes(b[i:i + 8]), i + 8
        elif w == 5:
            v, i = bytes(b[i:i + 4]), i + 4
        else:
            raise ValueError(f"wire type {w}")
        out.append((f, v))
    return out


def pb_get(b, *path):
    for p in path:
        hit = [v for f, v in pb_fields(b) if f == p]
        if not hit:
            return None
        b = hit[0]
    return b


def _cached(key, path, read):
    try:
        st = os.stat(path)
    except OSError:
        return None
    stamp = (st.st_mtime_ns, st.st_size)
    hit = _meter_cache.get(key)
    if hit and hit[0] == stamp:
        return hit[1]
    try:
        val = read(path)
    except Exception:  # an agent's file format is not ours to trust
        val = None
    _meter_cache[key] = (stamp, val)
    return val


def _sqlite_ro(path):
    import sqlite3
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=0.5)


def agy_meter(s):
    conv = s.get("conversation")
    if not conv:
        return None
    for h in agent_homes(s):
        db = h / ".gemini" / "antigravity-cli" / "conversations" / f"{conv}.db"
        wal = db.with_name(db.name + "-wal")
        stamp_path = wal if wal.exists() else db

        def read(_p, db=db):
            with _sqlite_ro(db) as c:
                row = c.execute("select data from gen_metadata order by idx desc limit 1").fetchone()
            cw = pb_get(row[0], 1, 9, 10) if row else None
            if cw is None:
                return None
            vals = dict((f, v) for f, v in pb_fields(cw) if isinstance(v, int))
            if not vals.get(4):
                return None
            return {"context": vals.get(1, 0), "window": vals[4], "limits": []}
        if db.exists():
            return _cached(("agy", str(db)), stamp_path, read)
    return None


def _window_label(minutes):
    if minutes == 10080:
        return "Weekly"
    if minutes and minutes % 1440 == 0:
        return f"{minutes // 1440}-day"
    return f"{round((minutes or 0) / 60)}-hour"


def codex_token_count(line):
    """A Codex rollout's token_count event as a meter, or None."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    p = ev.get("payload") or {}
    if p.get("type") != "token_count":
        return None
    info = p.get("info") or {}
    last = (info.get("last_token_usage") or {}).get("total_tokens")
    limits = []
    for w in ("primary", "secondary"):
        r = (p.get("rate_limits") or {}).get(w)
        if isinstance(r, dict) and r.get("used_percent") is not None:
            limits.append({"label": _window_label(r.get("window_minutes")),
                           "percent": float(r["used_percent"]), "resets_at": r.get("resets_at")})
    if last is None and not limits:
        return None
    return {"context": last, "window": info.get("model_context_window"), "limits": limits}


def codex_meter(s):
    d = s.get("dir")
    if not d:
        return None
    files = []
    for h in agent_homes(s):
        root = pathlib.Path(os.environ.get("CODEX_HOME") or h / ".codex") / "sessions"
        files += root.glob("*/*/*/rollout-*.jsonl")
    for f in sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)[:40]:
        try:
            with open(f, "rb") as fh:
                meta = json.loads(fh.readline() or b"{}")
        except (OSError, ValueError):
            continue
        if (meta.get("payload") or {}).get("cwd") != d:
            continue

        def read(p):
            with open(p, "rb") as fh:
                fh.seek(0, 2)
                fh.seek(max(0, fh.tell() - 262144))
                tail = fh.read().decode("utf-8", "replace").splitlines()
            for line in reversed(tail):
                if '"token_count"' in line and (m := codex_token_count(line)):
                    return m
            return None
        return _cached(("codex", str(f)), f, read)
    return None


def opencode_meter(s):
    sid = s.get("conversation")
    if not sid:
        return None
    for h in agent_homes(s):
        db = pathlib.Path(os.environ.get("OPENCODE_DB") or h / ".local" / "share" / "opencode" / "opencode.db")

        def read(_p, db=db):
            with _sqlite_ro(db) as c:
                cols = [r[1] for r in c.execute("pragma table_info(session_message)")]
                scol = next((x for x in cols if x.startswith("session")), None)
                if not scol or "data" not in cols:
                    return None
                rows = c.execute(f"select data from session_message where {scol} = ? order by rowid desc limit 20",
                                 (sid,)).fetchall()
            for (data,) in rows:
                m = json.loads(data)
                t = m.get("tokens") if isinstance(m, dict) else None
                if isinstance(t, dict) and (t.get("input") or t.get("output")):
                    cache = t.get("cache") or {}
                    return {"context": (t.get("input") or 0) + (cache.get("read") or 0) + (cache.get("write") or 0),
                            "window": None, "limits": []}
            return None
        if db.exists():
            wal = db.with_name(db.name + "-wal")
            return _cached(("opencode", str(db), sid), wal if wal.exists() else db, read)
    return None


def session_meter(s):
    """{context, window, percent, model, limits: [{label, percent,
    resets_at}]} for a session, or None when its agent left nothing."""
    agent = s.get("agent")
    m = None
    if agent == "claude":
        u = s.get("usage") or {}
        if u.get("context"):
            m = {"context": u["context"], "window": context_window(u.get("model")), "limits": [],
                 "model": u.get("model")}
    elif agent == "codex":
        m = codex_meter(s)
    elif agent == "agy":
        m = agy_meter(s)
    elif agent == "opencode":
        m = opencode_meter(s)
    if not m or not m.get("context"):
        return None
    m = dict(m)
    m["percent"] = min(100.0, 100.0 * m["context"] / m["window"]) if m.get("window") else None
    return m


def resets_in(ts, now):
    """"resets in 2 h", "resets in 3 days"."""
    try:
        d = int(ts) - now
    except (TypeError, ValueError):
        return None
    return "resets now" if d <= 0 else f"resets in {ago(d)}"


# ---------------------------------------------------------- session icons --
# A session's icon is built from a short, fixed list of shapes, never drawn
# freely, so no name can make it into a letter, a sign, or anything
# suggestive: every pair below was looked at, and only these exist.
# Outlines: no triangle (a warning sign) or octagon (a stop sign).
# Insides: nothing long and round-ended, and no pair of dots.
ICON_OUTLINES = ("circle", "squircle", "hexagon", "diamond")
ICON_INSIDES = ("dot", "ring", "half", "quarter", "orbit", "grid")
# a dot or a ring alone in a circle reads as a target or worse; only the
# other insides go in a circle
ICON_PAIRS = tuple((o, i) for o in ICON_OUTLINES for i in ICON_INSIDES
                   if not (o == "circle" and i in ("dot", "ring")))
# insides with a direction turn in quarters; orbit's moon sits at one of 8
ICON_TURNS = {"half": 4, "quarter": 4, "orbit": 8}


def session_icon(name):
    """A session's icon, the same every time for the same name, from the
    name's SHA-256: (outline, inside, turn, hue, inner hue). turn is the
    inside's direction, in steps (quarters, eighths for orbit); hues are
    degrees, the inside's 60-150 from the outline's so the two read apart."""
    import hashlib
    h = hashlib.sha256((name or "").encode()).digest()
    outline, inside = ICON_PAIRS[int.from_bytes(h[0:2], "big") % len(ICON_PAIRS)]
    turn = h[2] % ICON_TURNS.get(inside, 1)
    hue = int.from_bytes(h[3:5], "big") % 360
    hue2 = (hue + 60 + h[5] % 91) % 360
    return outline, inside, turn, hue, hue2


def hsl_rgb(h, s, l):
    """HSL (h in degrees, s and l 0-1) to RGB 0-1."""
    import colorsys
    return colorsys.hls_to_rgb(h / 360, l, s)
