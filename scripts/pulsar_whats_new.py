#!/usr/bin/python3
"""What's new in this release of Pulsar: the notes, and saying so once.

    pulsar_whats_new.py --notify    at login (pulsar-whats-new.service): the
                                    first login on a release this account has
                                    not seen, one notification with a "See
                                    what's new" button
    pulsar_whats_new.py --print     the current release's notes, as parsed

The notes are docs/releases.md, shipped as /usr/share/pulsar/releases.md;
the release is /usr/share/pulsar/release. The page itself is the welcome
app's (pulsar-welcome --whats-new), which imports this for the notes.

A new account is not told: its first login gets the welcome tour, which is
about everything, not what changed. The release it started on is recorded,
so the next one is news. The record is
$XDG_STATE_HOME/pulsar-welcome/release, the newest release announced; a
release is announced once, clicked or not, and only when it is newer than
that (by number: 26.9.1 < 26.10.1). A rollback, by hand or greenboot, says
nothing and leaves the record alone, so rolling forward again says nothing
either.

No GTK here: the notification side runs without a display toolkit, and the
tests read the notes without one.
"""
import html
import os
import pathlib
import re
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
RELEASE_FILE = pathlib.Path(os.environ.get("PULSAR_RELEASE_FILE", "/usr/share/pulsar/release"))
# from a checkout, the checkout's own notes
NOTES = [pathlib.Path(p) for p in ([os.environ["PULSAR_RELEASE_NOTES"]] if os.environ.get("PULSAR_RELEASE_NOTES")
                                   else ["/usr/share/pulsar/releases.md", str(HERE.parent / "docs" / "releases.md")])]
WELCOME = os.environ.get("PULSAR_WELCOME", "/usr/libexec/pulsar/pulsar-welcome")


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.environ.get("HOME", "/nonexistent"), ".local/state")
    return pathlib.Path(base)


def current_release():
    try:
        return RELEASE_FILE.read_text().strip()
    except OSError:
        return ""


def release_key(release):
    """26.10.1 -> (26, 10, 1), to compare as numbers (as strings 26.9.1
    would come after 26.10.1); None for anything not dotted numbers."""
    if not re.fullmatch(r"\d+(\.\d+)*", release):
        return None
    return tuple(int(x) for x in release.split("."))


def inline(text):
    """A line of the notes as Pango markup: `code`, **bold**, [link](url)."""
    out, pos = [], 0
    for m in re.finditer(r"`([^`]+)`|\*\*([^*]+)\*\*|\[([^\]]+)\]\([^)]*\)", text):
        out.append(html.escape(text[pos:m.start()], quote=False))
        if m.group(1) is not None:
            out.append(f"<tt>{html.escape(m.group(1), quote=False)}</tt>")
        elif m.group(2) is not None:
            out.append(f"<b>{html.escape(m.group(2), quote=False)}</b>")
        else:
            out.append(html.escape(m.group(3), quote=False))
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    return "".join(out)


def notes(release=None):
    """The release's notes: {"release", "lede", "sections": [(heading,
    [item markup, ...]), ...]}, or None when the notes have no section for
    it. Items are the bullets, their wrapped lines joined."""
    release = release or current_release()
    if not release:
        return None
    text = None
    for p in NOTES:
        try:
            text = p.read_text()
            break
        except OSError:
            continue
    if text is None:
        return None
    m = re.search(rf"^## {re.escape(release)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return None
    lede, sections, items, item = [], [], None, None
    for line in m.group(1).splitlines():
        if line.startswith("### "):
            items = []
            sections.append((line[4:].strip(), items))
            item = None
        elif line.startswith("- ") and items is not None:
            item = [line[2:].strip()]
            items.append(item)
        elif line.startswith("  ") and item is not None and line.strip():
            item.append(line.strip())
        elif line.strip() and items is None:
            lede.append(line.strip())
        elif not line.strip():
            item = None
    return {"release": release, "lede": inline(" ".join(lede)),
            "sections": [(h, [inline(" ".join(i)) for i in its]) for h, its in sections]}


def new_account():
    """The welcome is coming or just came: this login is the account's first."""
    st = state_dir()
    if (st / "pulsar-theme" / "welcome.pending").exists():
        return True
    try:
        return time.time() - (st / "pulsar-welcome" / "shown.json").stat().st_mtime < 600
    except OSError:
        return False


def notify():
    release = current_release()
    if not release:
        return 0
    rec = state_dir() / "pulsar-welcome" / "release"
    try:
        seen = rec.read_text().strip()
    except OSError:
        seen = ""
    # Only forward: a rollback to an older release, and the roll forward
    # again after it, are not news.
    cur, top = release_key(release), release_key(seen)
    if seen == release or (cur and top and cur <= top):
        return 0
    rec.parent.mkdir(parents=True, exist_ok=True)
    rec.write_text(release + "\n")
    n = notes(release)
    if new_account() or n is None:
        return 0
    body = re.sub(r"<[^>]+>", "", n["lede"])
    try:
        r = subprocess.run(["notify-send", "--app-name=Pulsar", "--icon=digital.arclight.Pulsar.Welcome",
                            "--action=open=See what's new", f"Updated to Pulsar {release}", html.unescape(body)],
                           capture_output=True, text=True)
    except OSError:
        return 0
    if r.stdout.strip() == "open":
        os.execv(WELCOME, [WELCOME, "--whats-new"])
    return 0


def main(argv):
    if argv[1:] == ["--notify"]:
        return notify()
    if argv[1:] == ["--print"]:
        n = notes()
        if n is None:
            print(f"no notes for release {current_release() or '(none)'}", file=sys.stderr)
            return 1
        print(f"{n['release']}: {n['lede']}")
        for h, items in n["sections"]:
            print(f"\n{h}")
            for i in items:
                print(f"  - {i}")
        return 0
    print("usage: pulsar_whats_new.py --notify | --print", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
