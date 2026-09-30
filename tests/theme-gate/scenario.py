#!/usr/bin/python3
"""The theme gate's scenarios. Runs inside the gate container (see
Containerfile and README.md), on a private session bus, with a headless
gnome-shell and HOME/XDG under a scratch dir. It never touches a host session.

  scenario.py gate [theme...]  per-release gate: selector drift, extension
                               health, contrast audit, every theme x variant
                               applied + screenshotted + pixel-checked, revert
                               fidelity. Writes shots/gate-report.json; exit 1
                               on any failure.
  scenario.py firstlogin       fresh account -> init -> shots;
                               revert -> stock GNOME; customised account ->
                               init leaves it alone.
  scenario.py restart          graceful restart: clean Text Editor restarts,
                               one with unsaved text keeps its dialog.
  scenario.py picker           screenshot the picker
  scenario.py glass            glass and light on, two monitors, scale 1 and
                               1.25: every surface's glass exists and sits
                               where its host does; nothing logged. Writes
                               glass-report.json; exit 1 on any failure.
  scenario.py desktops [theme...]
                               the site's desktop pictures: every theme x
                               variant with glass and light on
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

GATE = pathlib.Path("/gate")
SHOTS = pathlib.Path(os.environ.get("GATE_OUT", "/out"))
PT = ["/usr/libexec/pulsar/pulsar-theme"]
IMAGE = True   # always the engine as the image installed it
W, H = (int(x) for x in os.environ.get("SIZE", "2560x1600").split("x"))
ENV = dict(os.environ, WAYLAND_DISPLAY="wayland-0", GDK_BACKEND="wayland",
           PATH="/gate/bin:" + os.environ["PATH"])
ENV.pop("DISPLAY", None)
# (both paths movable, so tests/theme.bats can import this off the container)
LOG = open(os.environ.get("GATE_APPS_LOG", "/tmp/harness-apps.log"), "w")
# the Shell's own output, apart from the apps': shell_log_problems() reads it
SHELL_LOG = pathlib.Path(os.environ.get("GATE_SHELL_LOG", "/tmp/harness-shell.log"))
procs = []
EXT = "pulsar-theme@arclight.digital"


def sh(*a, check=True, env=None):
    return subprocess.run(a, check=check, text=True, capture_output=True, env=env)


def dconf(key, val):
    sh("dconf", "write", key, val)


def eval_js(js):
    r = sh("gdbus", "call", "--session", "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell",
           "--method", "org.gnome.Shell.Eval", js, check=False)
    m = re.match(r"\((true|false), '(.*)'\)$", r.stdout.strip(), re.S)
    return (m.group(1) == "true", m.group(2)) if m else (False, r.stdout + r.stderr)


def eval_json(js):
    """Eval of an expression that returns JSON.stringify(...): (value, "") or
    (None, why). The Shell JSON-encodes Eval's result, so a string comes back
    encoded twice."""
    from gi.repository import GLib
    r = sh("gdbus", "call", "--session", "--dest", "org.gnome.Shell", "--object-path", "/org/gnome/Shell",
           "--method", "org.gnome.Shell.Eval", js, check=False)
    try:
        ok, raw = GLib.Variant.parse(None, r.stdout.strip(), None, None).unpack()
    except Exception:
        return None, (r.stdout + r.stderr)[:300]
    if not ok:
        return None, raw[:300]
    try:
        v = json.loads(raw)
        return (json.loads(v) if isinstance(v, str) else v), ""
    except ValueError:
        return None, raw[:300]


def screenshot(name):
    SHOTS.mkdir(exist_ok=True)
    out = SHOTS / f"{name}.png"
    eval_js("Main.messageTray.getSources().forEach(s => s.destroy()); 1")
    time.sleep(0.7)
    sh("gdbus", "call", "--session", "--dest", "org.gnome.Shell.Screenshot", "--object-path",
       "/org/gnome/Shell/Screenshot", "--method", "org.gnome.Shell.Screenshot.Screenshot",
       "false", "false", str(out), check=False)
    return out


def pixel(png, x, y):
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    pb = GdkPixbuf.Pixbuf.new_from_file(str(png))
    px = pb.get_pixels()
    o = int(y) * pb.get_rowstride() + int(x) * pb.get_n_channels()
    return "#%02x%02x%02x" % (px[o], px[o + 1], px[o + 2])


def close(a, b, tol=10):
    a, b = [int(a[i:i + 2], 16) for i in (1, 3, 5)], [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return max(abs(x - y) for x, y in zip(a, b)) <= tol


def start_shell(extra_monitors=()):
    if not IMAGE:
        home = pathlib.Path(os.environ["HOME"])
        ext = home / ".local/share/gnome-shell/extensions"
        ext.mkdir(parents=True, exist_ok=True)
        for src in [GATE / "gate-harness@local"]:
            shutil.copytree(src, ext / src.name, dirs_exist_ok=True)
        dconf("/org/gnome/shell/enabled-extensions", f"['gamescale@arclight.digital', '{EXT}', 'gate-harness@local']")
        dconf("/org/gnome/shell/welcome-dialog-last-shown-version", "'999'")
        dconf("/org/gnome/desktop/interface/enable-animations", "false")
    out = open(SHELL_LOG, "a")
    mons = [a for m in [f"{W}x{H}", *extra_monitors] for a in ("--virtual-monitor", m)]
    p = subprocess.Popen(["gnome-shell", "--headless", "--wayland", "--no-x11", *mons],
                         stdout=out, stderr=out)
    procs.append(p)
    for _ in range(120):
        time.sleep(0.5)
        if eval_js("1")[0]:
            break
    else:
        raise SystemExit("gnome-shell did not come up")
    eval_js("Main.overview.hide()")
    # what gnome-session does in a real login: D-Bus-activated apps (and a
    # relaunched Text Editor is one) must know where the display is
    sh("dbus-update-activation-environment", "WAYLAND_DISPLAY=wayland-0", "GDK_BACKEND=wayland",
       "PATH=" + ENV["PATH"], check=False)


def stop_shell():
    kill_apps()
    for p in procs:
        p.terminate()
    for p in procs:
        try:
            p.wait(10)
        except Exception:
            p.kill()
    procs.clear()
    time.sleep(1)


# What in the Shell's log fails a run. glass.js catches its own errors and
# console.warn()s them ("pulsar-theme: glass: menu: ...") so that a broken
# glass never takes a Shell menu down with it -- which also means a glass
# that throws on every menu still draws every menu, and passes any pixel
# check. So the log is read: any of our warnings, and any JS error at all.
SHELL_LOG_FAIL = re.compile(r"pulsar-theme:|JS ERROR")
# Known harmless, each with why. Match the whole reason, never a bare
# "pulsar-theme:", or this list swallows the check.
SHELL_LOG_ALLOW = [
]


def shell_log_problems(name):
    """Lines in the Shell's log that fail the run. The log is kept beside the
    report as <name>-shell.log."""
    text = SHELL_LOG.read_text(errors="replace") if SHELL_LOG.exists() else ""
    SHOTS.mkdir(exist_ok=True)
    (SHOTS / f"{name}-shell.log").write_text(text)
    return [ln.strip() for ln in text.splitlines()
            if SHELL_LOG_FAIL.search(ln) and not any(re.search(pat, ln) for pat, _ in SHELL_LOG_ALLOW)]


SAMPLE = GATE / "sample.py"
TOP = 32
APPS = {
    "org.gnome.TextEditor": (["gnome-text-editor", "--standalone", str(SAMPLE)], (0, 0, .43, .5)),
    "org.gnome.Ptyxis": (["ptyxis", "--new-window", "--", "btop"], (0, .5, .43, .5)),
    "org.gnome.Adwaita1.Demo": (["adwaita-1-demo"], (.43, 0, .57, .5)),
    "gtk3-widget-factory": (["gtk3-widget-factory"], (.43, .5, .57, .5)),
}


def cell(cls):
    # windows are placed in logical pixels: SIZE over SCALE (desktops)
    sc = float(os.environ.get("SCALE", "1"))
    lw, lh = round(W / sc), round(H / sc)
    x, y, w, h = APPS[cls][1]
    ah = lh - TOP
    return round(x * lw) + 5, TOP + round(y * ah) + 5, round(w * lw) - 10, round(h * ah) - 10


def launch_apps():
    kill_apps()
    for cls, (argv, _) in APPS.items():
        procs.append(subprocess.Popen(argv, env=ENV, stdout=LOG, stderr=LOG, cwd=str(GATE)))
    for _ in range(60):
        time.sleep(0.5)
        have = eval_js("global.get_window_actors().map(a => a.meta_window.get_wm_class()).join(',')")[1]
        if all(c.lower() in have.lower() for c in APPS):
            break
    time.sleep(1.5)
    cells = {c: list(cell(c)) for c in APPS}
    # windows map at their own pace: tile, then re-tile until every one sits
    # in its cell (an untiled late window covers the probe points)
    for _ in range(8):
        placed = eval_js("let c=" + json.dumps(cells) + "; let n=0; for (const a of global.get_window_actors()) { const w=a.meta_window; "
                "const k=Object.keys(c).find(k => (w.get_wm_class()||'').toLowerCase()===k.toLowerCase()); if(!k) continue; "
                "const r=w.get_frame_rect(); if (Math.abs(r.x-c[k][0])<4 && Math.abs(r.y-c[k][1])<4) { n++; continue; } "
                "w.move_resize_frame(false, c[k][0], c[k][1], c[k][2], c[k][3]); } n")[1]
        if placed == str(len(APPS)):
            break
        time.sleep(1.0)
    time.sleep(1.0)


def kill_apps():
    for name in ("gnome-text-editor", "adwaita-1-demo", "ptyxis", "ptyxis-agent", "gtk3-widget-factory", "btop",
                 "pulsar-theme-picker"):
        # -x matches the kernel's process name, cut to 15 characters:
        # gnome-text-editor and gtk3-widget-factory never matched in full,
        # and every theme stacked a new copy of each over the last, their
        # shadows piling into near-black gutters in the desktop shots
        subprocess.run(["pkill", "-x", name[:15]], capture_output=True)
    time.sleep(0.8)
    # reap them: an app killed but never waited on stays a zombie, and btop
    # in the next desktop shot listed every one of them at 0B
    for p in procs[:]:
        if p.args and p.args[0] == "gnome-shell":
            continue
        if p.poll() is not None:
            procs.remove(p)


def pt(*args, check=True):
    r = subprocess.run(PT + list(args), text=True, capture_output=True, env=ENV)
    if check and r.returncode:
        print(r.stdout, r.stderr)
        raise SystemExit(f"pulsar-theme {' '.join(args)} failed")
    return r


def quick_settings(name, checked=False):
    """Screenshot Quick Settings; the checked toggles' boxes, or None when
    they could not be read. `checked`: Do Not Disturb on for the shot, so a
    toggle is checked whatever the scheme (Dark Style is the only other one
    this Shell has, and a light variant leaves it off)."""
    eval_js("global.get_window_actors().forEach(a => a.meta_window.minimize()); 1")
    if checked:
        dconf("/org/gnome/desktop/notifications/show-banners", "false")
    time.sleep(0.8)
    eval_js("Main.panel.statusArea.quickSettings.menu.open(false)")
    time.sleep(1.0)
    boxes, _ = eval_json("(() => { const out = []; const walk = a => { if (a.has_style_class_name?.('quick-toggle') && a.checked && a.is_mapped()) "
                         "{ const [x, y] = a.get_transformed_position(); out.push([x, y, a.width, a.height]); } "
                         "a.get_children().forEach(walk); }; walk(Main.panel.statusArea.quickSettings.menu.actor); "
                         "return JSON.stringify(out); })()")
    png = screenshot(name)
    eval_js("Main.panel.statusArea.quickSettings.menu.close(false)")
    if checked:
        sh("dconf", "reset", "/org/gnome/desktop/notifications/show-banners")
    return png, boxes


def theme_list():
    out = {}
    for ln in pt("list").stdout.splitlines():
        slug = ln[2:].split()[0]
        m = re.search(r"\[([a-z+]+)\]\s*$", ln)
        out[slug] = m.group(1).split("+") if m else ["dark"]
    return out


def palette(slug, mode):
    code = ("import json, sys; sys.path.insert(0, '/usr/libexec/pulsar'); import pulsar_theme_engine; "
            "pt = pulsar_theme_engine.load(); "
            f"v=pt.load_theme('{slug}').variants['{mode}']; "
            "print(json.dumps({k: v[k].hex for k in ('background','background_deep','window','view','accent','popover')}))")
    return json.loads(sh("python3", "-c", code, env=ENV).stdout)

# ------------------------------------------------------------------ gate --


def selector_drift():
    """Every class/id our Shell sheet targets must still exist in the stock
    Shell stylesheet of THIS GNOME. A missing one is a silent no-op today and
    a stock-grey surface after the next upgrade."""
    stock = sh("gresource", "extract", "/usr/share/gnome-shell/gnome-shell-theme.gresource",
               "/org/gnome/shell/theme/gnome-shell-dark.css").stdout
    tpl_path = pathlib.Path("/usr/share/pulsar/theme/templates/gnome-shell.css") if IMAGE \
        else GATE / "templates" / "gnome-shell.css"
    tpl = re.sub(r"/\*.*?\*/", "", tpl_path.read_text(), flags=re.S)
    missing = set()
    # Classes the extension itself puts on the Shell (glass.js: .pulsar-glass
    # on the UI group, .pulsar-overview-ground, ...) are looked for in the
    # extension's own code instead: one it no longer sets is drift too.
    ext = pathlib.Path("/usr/share/gnome-shell/extensions") / EXT
    ours = "\n".join(p.read_text() for p in ext.glob("*.js"))
    for sel in re.findall(r"([^{}]+)\{", tpl):
        for tok in re.findall(r"[.#][A-Za-z][\w-]*", sel):
            if tok.startswith(".pulsar-"):
                found = re.search(r"(?<![\w-])" + re.escape(tok[1:]) + r"(?![\w-])", ours)
            else:
                found = re.search(re.escape(tok) + r"(?![\w-])", stock)
            if not found:
                missing.add(tok)
    return sorted(missing)


def gate(only):
    report = {"gnome_shell": sh("gnome-shell", "--version").stdout.strip(), "checks": [], "themes": {}}
    add = lambda name, ok, detail="": report["checks"].append({"check": name, "ok": bool(ok), "detail": detail})

    drift = selector_drift()
    add("shell selectors exist in this GNOME's stock stylesheet", not drift, ", ".join(drift))
    r = pt("audit", *only, check=False)
    add("contrast audit (WCAG AA) on every theme", r.returncode == 0, "" if r.returncode == 0 else r.stdout[-400:])

    start_shell()
    state = eval_js(f"Main.extensionManager.lookup('{EXT}')?.state")[1]
    add("pulsar-theme extension ACTIVE", state == "1", f"state={state}")

    ok, detail = extension_stress()
    add("extension survives Dark Style flips, a switch and a revert, sheets bounded", ok, detail)
    if not ok:
        stop_shell()
        report["ok"] = False
        (SHOTS / "gate-report.json").write_text(json.dumps(report, indent=1))
        print("\n".join(f"{'PASS' if c['ok'] else 'FAIL'}  {c['check']}" + (f"  -- {c['detail']}" if c["detail"] else "")
                        for c in report["checks"]))
        print(f"GATE FAIL on {report['gnome_shell']}")
        return 1

    for slug, modes in theme_list().items():
        if only and slug not in only:
            continue
        for mode in modes:
            pt("set", slug, "--no-restart")
            if len(modes) == 2:
                dconf("/org/gnome/desktop/interface/color-scheme", "'prefer-dark'" if mode == "dark" else "'default'")
                time.sleep(0.8)
            pal = palette(slug, mode)
            launch_apps()
            desk = screenshot(f"{slug}-{mode}-desktop")
            qs, boxes = quick_settings(f"{slug}-{mode}-quicksettings", checked=True)
            ex, ey, ew, eh = cell("org.gnome.TextEditor")
            ax, ay, aw, ah = cell("org.gnome.Adwaita1.Demo")
            probes = {"top bar = background_deep": (pixel(qs, W * 0.30, 6), [pal["background_deep"]]),
                      "Text Editor view = background": (pixel(desk, ex + ew * 0.85, ey + eh * 0.9), [pal["background"]]),
                      "libadwaita content = window|view": (pixel(desk, ax + aw * 0.95, ay + ah * 0.93),
                                                            [pal["window"], pal["view"]])}
            found = [b for b in boxes or [] if all(isinstance(x, (int, float)) for x in b) and b[2] > 20]
            if found:
                bx, by, bw, bh = found[0]
                probes["checked quick toggle = accent"] = (pixel(qs, bx + bw * 0.93, by + bh / 2), [pal["accent"]])
            res = {k: {"ok": any(close(seen, w) for w in want), "seen": seen, "want": want}
                   for k, (seen, want) in probes.items()}
            if not found:
                # no toggle to sample is a failure, never a skipped check
                res["checked quick toggle = accent"] = {
                    "ok": False, "want": [pal["accent"]],
                    "seen": "no checked quick toggle could be read" if boxes is None else "no checked quick toggle"}
            res["Ptyxis palette applied"] = {"ok": f"pulsar-{slug}" in sh("dconf", "dump", "/org/gnome/Ptyxis/").stdout}
            report["themes"][f"{slug}/{mode}"] = res
            bad = [k for k, v in res.items() if not v["ok"]]
            print(f"  {slug:12} {mode:5} " + ("PASS" if not bad else "FAIL " + "; ".join(
                f"{k} (saw {res[k].get('seen')}, want {res[k].get('want')})" for k in bad)), flush=True)
            for k in bad:
                add(f"{slug}/{mode}: {k}", False, f"saw {res[k].get('seen')} want {res[k].get('want')}")
    kill_apps()
    ok, detail = revert_check()
    add("revert is byte-exact and dconf-exact", ok, detail)
    stop_shell()
    bad = shell_log_problems("gate")
    add("Shell log has no pulsar-theme warnings and no JS errors", not bad,
        f"{len(bad)} lines, first: " + " | ".join(bad[:5]) if bad else "")

    report["ok"] = all(c["ok"] for c in report["checks"])
    (SHOTS / "gate-report.json").write_text(json.dumps(report, indent=1))
    print("\n".join(f"{'PASS' if c['ok'] else 'FAIL'}  {c['check']}" + (f"  -- {c['detail']}" if c["detail"] else "")
                    for c in report["checks"]))
    print(f"GATE {'PASS' if report['ok'] else 'FAIL'} on {report['gnome_shell']}")
    return 0 if report["ok"] else 1


# ours, plus any null entry (an orphan the Shell could no longer unload):
# both count against the bound
SHEETS = ("(() => { const t = imports.gi.St.ThemeContext.get_for_stage(global.stage).get_theme();"
          " return t.get_custom_stylesheets().filter(f => !f || (f?.get_path?.() || '').includes('/pulsar-theme/shell/')).length; })()")


def extension_stress():
    """The extension's reload paths, hammered: a theme swap on every Dark
    Style flip, a switch, a revert. The Shell must keep answering, and at no
    point may more than one of our sheets be loaded."""
    counts = []
    steps = [("set pulsar", lambda: pt("set", "pulsar", "--no-restart"))]
    for i in range(6):
        v = "'default'" if i % 2 == 0 else "'prefer-dark'"
        steps.append((f"Dark Style -> {v}", lambda v=v: dconf("/org/gnome/desktop/interface/color-scheme", v)))
    steps += [("set gruvbox", lambda: pt("set", "gruvbox", "--no-restart")),
              ("revert", lambda: pt("revert", "--to", "image"))]
    for label, fn in steps:
        fn()
        time.sleep(1.2)
        ok, n = eval_js(SHEETS)
        if not ok:
            if not eval_js("1")[0]:
                return False, f"Shell stopped answering after: {label}"
            return False, f"could not count stylesheets after {label}: {n[:300]}"
        try:
            n = int(n.strip('"'))
        except ValueError:
            return False, f"could not count stylesheets after {label}: {n}"
        counts.append(n)
        if n > 1:
            return False, f"{n} of our stylesheets loaded after: {label} (counts so far {counts})"
    if counts[-1] != 0:
        return False, f"a stylesheet is still loaded after revert (counts {counts})"
    # revert disabled the extension for stock; the theme runs need it back
    shutil.rmtree(pathlib.Path(os.environ["XDG_STATE_HOME"]) / "pulsar-theme", ignore_errors=True)
    sh("dconf", "reset", "/org/gnome/shell/enabled-extensions")
    sh("dconf", "reset", "/org/gnome/desktop/interface/color-scheme")
    time.sleep(1.5)
    return True, f"stylesheet counts per step: {counts}"


def snapshot_tree():
    home = pathlib.Path(os.environ["HOME"])
    files = {}
    for p in home.rglob("*"):
        rel = str(p.relative_to(home))
        if p.is_file() and not any(x in p.parts for x in (".cache", "dconf", "extensions", "gvfs-metadata")) \
                and not rel.startswith(".local/state/pulsar-theme"):
            files[rel] = p.read_bytes()
    return files, sh("dconf", "dump", "/").stdout


def revert_check():
    pt("revert", "--to", "image")
    shutil.rmtree(pathlib.Path(os.environ["XDG_STATE_HOME"]) / "pulsar-theme", ignore_errors=True)
    cfg = pathlib.Path(os.environ["XDG_CONFIG_HOME"])
    (cfg / "gtk-4.0").mkdir(parents=True, exist_ok=True)
    (cfg / "gtk-4.0" / "gtk.css").write_text("/* the user's own tweak */\nwindow { border-radius: 0; }\n")
    (cfg / "btop").mkdir(parents=True, exist_ok=True)
    (cfg / "btop" / "btop.conf").write_text('color_theme = "Default"\nupdate_ms = 1500\n')
    dconf("/org/gnome/desktop/interface/accent-color", "'green'")
    before_f, before_k = snapshot_tree()
    for t in ("pulsar", "tokyo-night", "gruvbox"):
        pt("set", t, "--no-restart")
    pt("revert", "--to", "image")
    after_f, after_k = snapshot_tree()
    df = sorted(k for k in set(before_f) | set(after_f) if before_f.get(k) != after_f.get(k))
    return (not df and before_k == after_k), (f"files differ: {df}" if df else "") + \
        ("" if before_k == after_k else " dconf differs")

# ------------------------------------------------------------ firstlogin --


def firstlogin():
    home = pathlib.Path(os.environ["HOME"])
    print("== 1. fresh account: pulsar-theme-init.service's ExecStart, before the Shell")
    print(pt("init").stdout.strip())
    print("   stamp:", (home / ".local/state/pulsar-theme/init.json").read_text().replace("\n", " "))
    start_shell()
    print("   extension state:", eval_js(f"Main.extensionManager.lookup('{EXT}')?.state")[1])
    launch_apps()
    screenshot("firstlogin-1-fresh-desktop")
    quick_settings("firstlogin-1-fresh-quicksettings")
    print("== 2. pulsar theme revert -> stock GNOME")
    print(pt("revert").stdout.strip())
    stop_shell()
    start_shell()
    launch_apps()
    screenshot("firstlogin-2-after-revert-desktop")
    quick_settings("firstlogin-2-after-revert-quicksettings")
    print("   next login's init:", pt("init").stdout.strip())
    stop_shell()
    print("== 3. an existing account with its own gtk.css and accent")
    for p in home.iterdir():
        shutil.rmtree(p) if p.is_dir() else p.unlink()
    sh("dconf", "reset", "-f", "/")
    (home / ".config/gtk-4.0").mkdir(parents=True)
    (home / ".config/gtk-4.0/gtk.css").write_text("/* mine */\n:root { --window-bg-color: #202020; }\n")
    dconf("/org/gnome/desktop/interface/accent-color", "'red'")
    print(pt("init").stdout.strip())
    print("   stamp:", (home / ".local/state/pulsar-theme/init.json").read_text().replace("\n", " "))
    print("   gtk.css untouched:", (home / ".config/gtk-4.0/gtk.css").read_text().startswith("/* mine */"))
    start_shell()
    launch_apps()
    screenshot("firstlogin-3-customised-desktop")
    stop_shell()

# --------------------------------------------------------------- restart --


def te_pids():
    return sh("pgrep", "-f", "gnome-text-editor", check=False).stdout.split()


def type_into_text_editor(text):
    eval_js("(() => { const w = global.get_window_actors().map(a => a.meta_window)"
            ".find(w => (w.get_wm_class()||'') === 'org.gnome.TextEditor'); w.activate(global.get_current_time()); })()")
    time.sleep(0.8)
    keys = ", ".join(str(ord(c)) for c in text)
    print("   typing:", eval_js(
        "(() => { const C = imports.gi.Clutter; const seat = global.stage.context.get_backend().get_default_seat();"
        " const kb = seat.create_virtual_device(C.InputDeviceType.KEYBOARD_DEVICE); let t = imports.gi.GLib.get_monotonic_time();"
        f" for (const u of [{keys}]) {{ const kv = C.unicode_to_keysym(u); kb.notify_keyval(t++, kv, C.KeyState.PRESSED);"
        " kb.notify_keyval(t++, kv, C.KeyState.RELEASED); } return 'typed'; })()"))
    time.sleep(1.0)


def notes_pids():
    return sh("pgrep", "-f", "fixtures/notes.py", check=False).stdout.split()


def restart():
    apps = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / "digital.arclight.GateNotes.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Notes (fixture)\n"
        "Exec=python3 /gate/fixtures/notes.py\n")
    start_shell()
    pt("set", "pulsar", "--no-restart")
    procs.append(subprocess.Popen(["gnome-text-editor", str(SAMPLE)], env=ENV, stdout=LOG, stderr=LOG))
    procs.append(subprocess.Popen(["python3", "/gate/fixtures/notes.py"], env=ENV, stdout=LOG, stderr=LOG))
    procs.append(subprocess.Popen(["ptyxis", "--new-window"], env=ENV, stdout=LOG, stderr=LOG))
    time.sleep(5)
    print("== restart-apps sees:\n" + pt("restart-apps").stdout.rstrip())
    te0, n0 = te_pids(), notes_pids()
    print("== set gruvbox --restart (nothing unsaved)\n" + pt("set", "gruvbox", "--restart").stdout.rstrip())
    for i in range(12):
        time.sleep(1)
        wins = eval_js("global.get_window_actors().map(a => a.meta_window.get_title()).join(' | ')")[1]
        if "Text Editor" in wins:
            break
    print(f"   Text Editor window after {i + 1}s:", "Text Editor" in wins)
    te1, n1 = te_pids(), notes_pids()
    print(f"   Text Editor pid {te0} -> {te1}: {'RESTARTED' if te1 and te1 != te0 else 'NOT restarted'}")
    print(f"   Notes       pid {n0} -> {n1}: {'RESTARTED' if n1 and n1 != n0 else 'NOT restarted'}")
    print("   windows:", eval_js("global.get_window_actors().map(a => a.meta_window.get_title()).join(' | ')")[1])
    screenshot("restart-1-clean-restarted")
    # now Notes holds unsaved text
    subprocess.run(["pkill", "-f", "fixtures/notes.py"])
    time.sleep(1)
    procs.append(subprocess.Popen(["python3", "/gate/fixtures/notes.py", "--dirty"], env=ENV, stdout=LOG, stderr=LOG))
    time.sleep(3)
    n0 = notes_pids()
    print("== set tokyo-night --restart (Notes has unsaved text)\n" + pt("set", "tokyo-night", "--restart").stdout.rstrip())
    time.sleep(1)
    n1 = notes_pids()
    print(f"   Notes pid {n0} -> {n1}: {'KEPT OPEN -- its own Save Changes? dialog is up' if n1 == n0 else 'EXITED'}")
    print("   windows:", eval_js("global.get_window_actors().map(a => a.meta_window.get_title()).join(' | ')")[1])
    eval_js("global.get_window_actors().map(a => a.meta_window).filter(w => w.get_title() === 'Notes')"
            ".forEach(w => w.activate(global.get_current_time())); 1")
    time.sleep(1)
    screenshot("restart-2-unsaved-dialog")
    print("== no TTY: never prompts\n" + pt("set", "nord").stdout.rstrip())
    print("== don't ask again\n" + pt("config", "restart-prompt", "off").stdout.rstrip())
    stop_shell()


def picker():
    start_shell()
    pt("set", "pulsar", "--no-restart")
    procs.append(subprocess.Popen(["gnome-text-editor", str(SAMPLE)], env=ENV, stdout=LOG, stderr=LOG))
    time.sleep(3)
    procs.append(subprocess.Popen([PT[0] + "-picker"], env=ENV, stdout=LOG, stderr=LOG))
    time.sleep(5)
    place = ("for (const a of global.get_window_actors()) { const w=a.meta_window; if (w.get_title() !== 'Themes') continue;"
             f" w.move_resize_frame(false, {W // 2 - 800}, {H // 2 - 600}, 1600, 1200); w.activate(global.get_current_time()); }} 1")
    eval_js(place)
    time.sleep(1.5)
    screenshot("picker")
    subprocess.run(["pkill", "-f", "pulsar-theme-picker"])
    time.sleep(1)
    procs.append(subprocess.Popen([PT[0] + "-picker"], env=dict(ENV, PULSAR_PICKER_AUTOPICK="tokyo-night"),
                                  stdout=LOG, stderr=LOG))
    time.sleep(3)
    eval_js(place)
    time.sleep(4)
    screenshot("picker-restart-dialog")
    stop_shell()


def set_scale(scale):
    """Every virtual monitor's scale, through Mutter's DisplayConfig: the
    nearest one each one's current mode supports. The first is primary; the
    others stand in a row to its right, along the top edge."""
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    def call(method, args=None):
        return bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                             "org.gnome.Mutter.DisplayConfig", method, args, None, 0, -1, None).unpack()
    serial, monitors, _logical, props = call("GetCurrentState")
    # 1: logical (framebuffer scaling), where positions are in logical pixels
    logical_layout = props.get("layout-mode", 1) == 1
    config, x, got = [], 0, []
    for i, mon in enumerate(monitors):
        mode = [m for m in mon[1] if m[6].get("is-current")][0]
        sc = min(mode[5], key=lambda s: abs(s - scale))
        config.append((x, 0, sc, 0, i == 0, [(mon[0][0], mode[0], {})]))
        x += round(mode[1] / sc) if logical_layout else mode[1]
        got.append(sc)
    call("ApplyMonitorsConfig", GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})", (serial, 1, config, {})))
    time.sleep(2)
    print(f"  scale {' + '.join(f'{sc:g}' for sc in got)}", flush=True)
    return got


# A full Quick Settings panel for the site's pictures, as a laptop has it.
# The gate's Shell has no NetworkManager, Bluetooth, UPower, audio or
# backlight, so the stock items for them stay hidden; these are the Shell's
# own QuickToggle / QuickMenuToggle / QuickSlider classes, in the stock
# order, beside the stock Dark Style and Do Not Disturb toggles. Idempotent.
QS_FULL = r"""(() => {
  if (global._pulsarQS) return 'already';
  global._pulsarQS = true;
  const qs = Main.panel.statusArea.quickSettings, menu = qs.menu;
  const {Gio, GObject, St} = imports.gi;
  // the top bar as a laptop's: network and volume beside the battery, and
  // not the gate's own unsafe-mode lock (it drives the Shell over Eval)
  qs._unsafeMode.hide();
  for (const n of ['audio-volume-medium-symbolic', 'network-wireless-signal-excellent-symbolic'])
    qs._indicators.insert_child_at_index(new St.Icon({icon_name: n, style_class: 'system-status-icon'}), 0);
  import('resource:///org/gnome/shell/ui/quickSettings.js').then(m => {
    // the battery, and the lock button the gate's session hides
    const sys = qs._system.quickSettingsItems[0];
    sys._powerToggle.set({title: '79%', gicon: new Gio.ThemedIcon({name: 'battery-level-80-symbolic'})});
    sys._powerToggle.visible = true;
    for (const c of sys.child.get_children())
      if (GObject.type_name(c.constructor.$gtype).includes('LockItem')) c.visible = true;
    const dark = qs._darkMode.quickSettingsItems[0];
    const dnd = qs._doNotDisturb.quickSettingsItems[0];
    const slider = (icon, v) => { const s = new m.QuickSlider({iconName: icon}); s.slider.value = v; return s; };
    menu.insertItemBefore(slider('audio-volume-medium-symbolic', 0.6), dark, 2);
    menu.insertItemBefore(slider('display-brightness-symbolic', 0.5), dark, 2);
    for (const t of [
      new m.QuickMenuToggle({title: 'Wi-Fi', subtitle: 'Home', iconName: 'network-wireless-signal-excellent-symbolic', toggleMode: true, checked: true, menuEnabled: true}),
      new m.QuickMenuToggle({title: 'Bluetooth', iconName: 'bluetooth-disabled-symbolic', toggleMode: true, menuEnabled: true}),
      new m.QuickMenuToggle({title: 'Power Mode', subtitle: 'Balanced', iconName: 'power-profile-balanced-symbolic', menuEnabled: true}),
      new m.QuickToggle({title: 'Night Light', iconName: 'night-light-symbolic', toggleMode: true}),
    ])
      menu.insertItemBefore(t, dark);
    const air = new m.QuickToggle({title: 'Airplane Mode', iconName: 'airplane-mode-symbolic', toggleMode: true});
    const next = dnd.get_next_sibling();
    if (next) menu.insertItemBefore(air, next); else menu.addItem(air);
  }).catch(e => logError(e, 'pulsar QS_FULL'));
  return 'ok';
})()"""


def full_quick_settings():
    print("  quick settings:", eval_js(QS_FULL)[1], flush=True)
    time.sleep(1)


def desktops(only):
    """The site's desktop pictures: every theme x variant with the effects on,
    as a new account has them (the gate's own account has them off). Apps
    start after each theme is set, since GTK takes the glass half at launch."""
    for k in ("glass", "window-glass", "lighting", "power-on", "glow"):
        dconf(f"/org/gnome/shell/extensions/pulsar-theme/{k}", "true")
    # SCALE (1.25 with SIZE=3200x2000): the desktop laid out at SIZE/SCALE
    # -- the 2560x1600 the four apps' cells need -- and drawn at every pixel
    # of SIZE, so the picture is sharper than the layout. A fractional scale
    # needs Mutter's framebuffer scaling, set before the Shell starts.
    if os.environ.get("SCALE") and float(os.environ["SCALE"]) % 1:
        dconf("/org/gnome/mutter/experimental-features", "['scale-monitor-framebuffer']")
    start_shell()
    if os.environ.get("SCALE"):
        set_scale(float(os.environ["SCALE"]))
    full_quick_settings()
    for slug, modes in theme_list().items():
        if only and slug not in only:
            continue
        for mode in modes:
            kill_apps()
            pt("set", slug, "--no-restart")
            if len(modes) == 2:
                dconf("/org/gnome/desktop/interface/color-scheme", "'prefer-dark'" if mode == "dark" else "'default'")
            # the theme's wallpaper, when the builder's render is not in
            # this image (WALLS: a directory of <slug>-<mode>.png)
            wall = pathlib.Path(os.environ.get("WALLS", "/nonexistent")) / f"{slug}-{mode}.png"
            if wall.exists():
                for k in ("picture-uri", "picture-uri-dark"):
                    dconf(f"/org/gnome/desktop/background/{k}", f"'file://{wall}'")
            time.sleep(1.5)
            launch_apps()
            time.sleep(2)
            # Quick Settings open over the apps: glass, light and Glow in
            # one frame (its checked toggles and slider are accent-filled)
            eval_js("Main.panel.statusArea.quickSettings.menu.open(); 1")
            time.sleep(1.5)
            screenshot(f"{slug}-{mode}-desktop")
            eval_js("Main.panel.statusArea.quickSettings.menu.close(); 1")
            print(f"  {slug:12} {mode:5} shot", flush=True)
    kill_apps()
    stop_shell()


# ----------------------------------------------------------------- glass --

# The glass on each surface, as glass.js keeps it: a Surface per offscreen-
# painted host (a menu's BoxPointer, an OSD, the banner bin, the dash) with a
# mirror under it (the blur) and one over it (the light), and a WindowGlass
# per GTK window with its blur inside the window actor. It reads glass.js's
# own bookkeeping (Glass._surfaces, Glass._windows, Surface._under/_over/
# _backdrop/_lightActor/_box, WindowGlass._backdrop): if glass.js renames
# them, this fails loudly with "update GLASS_PROBE", never passes silently.
# Every rectangle is in stage pixels, off the actors' transforms.
GLASS_PROBE = r"""(() => {
  const g = Main.extensionManager.lookup('EXT')?.stateObj?._glass;
  if (!(g?._surfaces instanceof Map) || !(g?._windows instanceof Map))
    return JSON.stringify([{name: 'glass', error: 'no Glass with _surfaces and _windows: the extension is off, or ' +
      'glass.js renamed its internals (update GLASS_PROBE in scenario.py)'}]);
  const r = a => { const [x, y] = a.get_transformed_position(); const [w, h] = a.get_transformed_size();
    return [x, y, w, h].map(v => Math.round(v * 100) / 100); };
  const layer = a => a ? {rect: r(a), visible: a.visible, mapped: a.is_mapped()} : null;
  const surf = (name, host) => {
    if (!host) return {name, error: 'the Shell has no such actor'};
    const o = {name, kind: 'surface', host: r(host), shown: host.visible && host.is_mapped(), opacity: host.opacity};
    const s = g._surfaces.get(host);
    if (!s) return Object.assign(o, {error: 'no glass surface for it'});
    o.box = s._box ? r(s._box) : null;
    for (const [k, m, next] of [['under', s._under, 'get_next_sibling'], ['over', s._over, 'get_previous_sibling']])
      o[k] = m ? Object.assign(layer(m), {opacity: m.opacity, parent: m.get_parent() === host.get_parent(),
                                          beside: m[next]() === host}) : null;
    o.blur = layer(s._backdrop);
    o.light = layer(s._lightActor);
    return o;
  };
  const win = w => {
    const a = w.get_compositor_private(), f = w.get_frame_rect();
    const o = {name: 'window ' + (w.get_gtk_application_id?.() || w.get_wm_class()) + (w.get_transient_for() ? ' popup' : ''),
               kind: 'window', frame: [f.x, f.y, f.width, f.height], monitor: w.get_monitor(), shown: !!a?.is_mapped()};
    const wg = a && g._windows.get(a);
    if (!wg) return Object.assign(o, {error: 'no window glass for it'});
    o.blur = wg._backdrop ? Object.assign(layer(wg._backdrop), {inWindow: wg._backdrop.get_parent() === a}) : null;
    return o;
  };
  const out = [];
  WHAT
  return JSON.stringify(out); })()""".replace("EXT", EXT)


def near(a, b, tol):
    return abs(a - b) <= tol


def finite(*rects):
    return all(r and all(isinstance(v, (int, float)) for v in r) for r in rects)


def glass_faults(rec, tol=1.5):
    """What is wrong with one probed surface or window, as readable lines."""
    if rec.get("error"):
        return [rec["error"]]
    # a NaN in the Shell comes back as null: an actor placed at NaN never draws
    rects = [rec.get("host") or rec.get("frame"), rec.get("box")] + \
        [(rec.get(k) or {}).get("rect") for k in ("under", "over", "blur", "light")]
    if not finite(*[r for r in rects if r is not None]):
        return [f"a rectangle is not a number: {rects}"]
    f = []
    if not rec.get("shown"):
        f.append("not on screen (the fixture did not show it)")
    if rec["kind"] == "surface":
        host = rec["host"]
        for k in ("under", "over"):
            m = rec.get(k)
            if not m:
                f.append(f"no {k} mirror")
                continue
            if not m["parent"]:
                f.append(f"{k} mirror is not in the host's parent")
            elif not m["beside"]:
                f.append(f"{k} mirror is not stacked right {'below' if k == 'under' else 'above'} the host")
            if not (m["visible"] and m["mapped"]):
                f.append(f"{k} mirror hidden while the host shows")
            if m["opacity"] != rec["opacity"]:
                f.append(f"{k} mirror opacity {m['opacity']}, host {rec['opacity']}")
            if not all(near(a, b, tol) for a, b in zip(m["rect"], host)):
                f.append(f"{k} mirror at {m['rect']}, host at {host}")
        box = rec.get("box")
        if not box:
            f.append("no styled box to shape the glass to")
        # the blur and the light reach past the box by a pad on every side
        # (a shadow, a glow): centered on it and covering it, whatever the pad
        for k in ("blur", "light"):
            lay = rec.get(k)
            if not lay:
                f.append(f"no {k} layer")
            elif not (lay["visible"] and lay["mapped"]):
                f.append(f"{k} layer hidden with the effect on")
            elif box:
                f += covers(k, lay["rect"], box, tol)
    else:
        lay = rec.get("blur")
        if not lay:
            f.append("no blur layer")
        elif not (lay["visible"] and lay["mapped"] and lay["inWindow"]):
            f.append(f"blur layer not shown in the window (visible={lay['visible']} mapped={lay['mapped']} "
                     f"inWindow={lay['inWindow']})")
        else:
            f += covers("blur", lay["rect"], rec["frame"], tol)
    return f


def covers(k, outer, inner, tol):
    ox, oy, ow, oh = outer
    ix, iy, iw, ih = inner
    f = []
    if not (near(ox + ow / 2, ix + iw / 2, tol) and near(oy + oh / 2, iy + ih / 2, tol)):
        f.append(f"{k} layer {outer} is not centered on {inner}")
    if ow < iw - tol or oh < ih - tol:
        f.append(f"{k} layer {outer} is smaller than {inner}")
    return f


def probe_glass(what, settle=6.0):
    """Probe until every surface in `what` (JS pushing onto `out`) is right,
    or `settle` seconds have gone: glass lays out a frame after its host."""
    js = GLASS_PROBE.replace("WHAT", what)
    t0, recs, faults = time.monotonic(), [], {"probe": ["no answer"]}
    while True:
        recs, why = eval_json(js)
        if recs is None:
            faults = {"probe": [f"Eval failed: {why}"]}
        else:
            faults = {r["name"]: glass_faults(r) for r in recs}
            if not any(faults.values()):
                break
        if time.monotonic() - t0 > settle:
            break
        time.sleep(0.3)
    return recs, faults


def wait_for(js, want="true", secs=10.0):
    """Poll a Shell expression until it is `want` (as Eval prints it)."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        if eval_js(js)[1] == want:
            return True
        time.sleep(0.25)
    return False


# The second monitor the glass scenario adds, right of the first: past glass
# bugs lived there (e0b025a: blur reaching into a neighbor was never redrawn).
GLASS_SECOND = "1920x1200"
GLASS_SCALES = (1.0, 1.25)
POPOVER_APP = "digital.arclight.GatePopover"


def popover_action(name):
    sh("gdbus", "call", "--session", "--dest", POPOVER_APP, "--object-path", "/digital/arclight/GatePopover",
       "--method", "org.gtk.Actions.Activate", name, "[]", "{}", check=False)


def glass():
    """Glass and light on, two monitors, at 1.0 and 1.25: for each surface
    (Quick Settings, a desktop menu on the second monitor, the OSD on each
    monitor, a banner, the dash, a GTK4 window, a GTK popover) the glass
    exists, sits exactly where its host does, shows while it shows, and
    nothing in the Shell's log says glass.js caught an error. Writes
    glass-report.json; exit 1 on any failure."""
    for k in ("glass", "window-glass", "lighting", "power-on", "glow", "focus-brackets"):
        dconf(f"/org/gnome/shell/extensions/pulsar-theme/{k}", "true")
    # (Mutter 50 lays out in logical pixels and takes 1.25 as it is: no
    # scale-monitor-framebuffer, which it logs as an unknown feature)
    start_shell(extra_monitors=[GLASS_SECOND])
    # the theme after the switches, before the apps: GTK takes its glass half
    # (translucent grounds) from gtk.css at launch
    pt("set", "pulsar", "--no-restart")
    kill_apps()
    procs.append(subprocess.Popen(["adwaita-1-demo"], env=ENV, stdout=LOG, stderr=LOG))
    procs.append(subprocess.Popen(["python3", "/gate/fixtures/popover.py"], env=ENV, stdout=LOG, stderr=LOG))
    report = {"gnome_shell": sh("gnome-shell", "--version").stdout.strip(), "runs": {}, "checks": []}
    add = lambda name, ok, detail="": report["checks"].append({"check": name, "ok": bool(ok), "detail": detail})
    apps = ("org.gnome.Adwaita1.Demo", POPOVER_APP)
    up = wait_for("['" + "','".join(apps) + "'].every(id => global.get_window_actors()"
                  ".some(a => a.meta_window.get_gtk_application_id?.() === id))", secs=30)
    add("the GTK4 windows came up", up)
    for scale in GLASS_SCALES:
        got = set_scale(scale)
        tag = f"scale {scale:g}"
        mons, _ = eval_json("JSON.stringify(Main.layoutManager.monitors.map(m => [m.x, m.y, m.width, m.height]))")
        if not mons or len(mons) < 2:
            add(f"{tag}: two monitors", False, f"monitors: {mons}")
            continue
        (px, py, _pw, _ph), (sx, sy, _sw, _sh) = mons[0], mons[1]
        # the demo on the first monitor, the popover's window on the second
        place = {"org.gnome.Adwaita1.Demo": [px + 60, py + 80, 1000, 700], POPOVER_APP: [sx + 60, sy + 80, 700, 500]}
        placed = wait_for("(() => { const c = " + json.dumps(place) + "; let n = 0; for (const a of global.get_window_actors()) { "
                          "const w = a.meta_window, k = w.get_gtk_application_id?.(); if (!c[k] || w.get_transient_for()) continue; "
                          "const r = w.get_frame_rect(); if (Math.abs(r.x - c[k][0]) < 4 && Math.abs(r.y - c[k][1]) < 4) n++; "
                          "else w.move_resize_frame(false, ...c[k]); } return n; })()", want=str(len(place)))
        add(f"{tag}: windows placed on both monitors", placed)
        run = {}

        def check(label, what, before="", after="", settle=6.0):
            if before:
                eval_js(f"try {{ {before}; }} catch (e) {{ log('gate: ' + e); }} 1")
            recs, faults = probe_glass(what, settle)
            if after:
                eval_js(f"try {{ {after}; }} catch (e) {{ log('gate: ' + e); }} 1")
            run[label] = recs
            bad = {k: v for k, v in faults.items() if v}
            add(f"{tag}: {label}", not bad and bool(recs),
                "; ".join(f"{k}: {', '.join(v)}" for k, v in bad.items()) if bad else
                ("" if recs else "nothing probed"))

        qs = "Main.panel.statusArea.quickSettings.menu"
        check("Quick Settings", f"out.push(surf('quick settings', {qs}._boxPointer))",
              before=f"{qs}.open(false)", after=f"{qs}.close(false)")
        # a desktop menu on the second monitor, opened where a click would
        bg = "Main.layoutManager._bgManagers[1].backgroundActor._backgroundMenu"
        check("desktop menu on the second monitor", f"out.push(surf('desktop menu', {bg}._boxPointer))",
              before=f"Main.layoutManager.setDummyCursorGeometry({sx + 300}, {sy + 300}, 0, 0); {bg}.open(false)",
              after=f"{bg}.close(false)")
        # the OSD on each monitor, held up: it hides itself after 1.5s
        check("OSD on each monitor",
              "Main.osdWindowManager._osdWindows.forEach((o, i) => out.push(surf('osd ' + i, o)))",
              before="Main.osdWindowManager.showAll(new imports.gi.Gio.ThemedIcon({name: 'audio-volume-medium-symbolic'}), "
                     "'Volume', 0.5, 1); for (const o of Main.osdWindowManager._osdWindows) if (o._hideTimeoutId) { "
                     "imports.gi.GLib.source_remove(o._hideTimeoutId); o._hideTimeoutId = 0; }",
              after="Main.osdWindowManager.hideAll()")
        # a critical banner: it stays until it is dismissed
        check("notification banner", "out.push(surf('banner', Main.messageTray._bannerBin))",
              before="import('resource:///org/gnome/shell/ui/messageTray.js').then(m => { "
                     "const src = new m.Source({title: 'Pulsar glass'}); Main.messageTray.add(src); "
                     "src.addNotification(new m.Notification({source: src, title: 'Glass', body: 'a banner', "
                     "urgency: m.Urgency.CRITICAL})); })",
              after="Main.messageTray.getSources().forEach(s => s.destroy())")
        check("dash", "out.push(surf('dash', Main.overview.dash))",
              before="Main.overview.show()", after="Main.overview.hide()")
        wait_for("Main.overview.visible", want="false", secs=5)
        wins = ("global.get_window_actors().map(a => a.meta_window).filter(w => ['" + "','".join(apps) +
                "'].includes(w.get_gtk_application_id?.()) && !w.get_transient_for()).forEach(w => out.push(win(w)))")
        check("GTK4 windows", wins)
        popped = ("global.get_window_actors().map(a => a.meta_window).filter(w => w.get_transient_for() && "
                  "w.get_transient_for().get_gtk_application_id?.() === '" + POPOVER_APP + "')")
        popover_action("popup")
        opened = wait_for(popped + ".length > 0", secs=8)
        if opened:
            check("GTK popover on the second monitor", popped + ".forEach(w => out.push(win(w)))")
        else:
            add(f"{tag}: GTK popover on the second monitor", False, "the fixture's popover never opened a window")
        popover_action("popdown")
        wait_for(popped + ".length", want="0", secs=5)
        report["runs"][tag] = {"scales": got, "monitors": mons, "probed": run}
    kill_apps()
    stop_shell()
    bad = shell_log_problems("glass")
    add("Shell log has no pulsar-theme warnings and no JS errors", not bad,
        f"{len(bad)} lines, first: " + " | ".join(bad[:5]) if bad else "")
    report["ok"] = all(c["ok"] for c in report["checks"])
    SHOTS.mkdir(exist_ok=True)
    (SHOTS / "glass-report.json").write_text(json.dumps(report, indent=1))
    print("\n".join(f"{'PASS' if c['ok'] else 'FAIL'}  {c['check']}" + (f"  -- {c['detail']}" if c["detail"] else "")
                    for c in report["checks"]))
    print(f"GLASS {'PASS' if report['ok'] else 'FAIL'} on {report['gnome_shell']}")
    return 0 if report["ok"] else 1


# ----------------------------------------------------------------- leaks --

# Every visible Shell widget under ROOT, in every state it can take, as the
# Shell itself resolves it: background, text and border color off its theme
# node. Keys are a path of style classes and child indices, so the same
# widget has the same key under any theme.
WALK = r"""(() => { const St = imports.gi.St; const out = {};
  const nm = a => { const id = a.get_name?.() || ''; const c = (a.get_style_class_name?.() || '').trim();
    return (id ? '#' + id : '') + (c ? '.' + c.split(' ').filter(Boolean).join('.') : '') || a.constructor.$gtype?.name || 'actor'; };
  const col = c => (c && c.alpha) ? [c.red, c.green, c.blue, c.alpha].join(',') : null;
  const shadow = n => col(n.get_box_shadow()?.color);
  // only labels, icons and entries draw in their text color; a container's
  // is only what its children inherit
  const leaf = a => a instanceof St.Label || a instanceof St.Icon || a instanceof St.Entry;
  const leaves = (a, path, fn) => a.get_children().forEach((c, i) => {
    if (!c.visible) return;
    const p = path + ' > ' + nm(c) + '[' + i + ']';
    if (c instanceof St.Widget && leaf(c)) fn(c, p);
    leaves(c, p, fn);
  });
  const walk = (a, path, d) => {
    if (!a.visible || d > 60) return;
    if (a instanceof St.Widget && a.is_mapped()) {
      a.ensure_style();
      const n = a.get_theme_node();
      out[path + '|'] = [col(n.get_background_color()), leaf(a) ? col(n.get_foreground_color()) : null,
                         col(n.get_border_color(St.Side.TOP)), shadow(n)];
      if (a.reactive || a.can_focus || a.track_hover) {
        for (const st of ['hover', 'focus', 'active', 'checked', 'selected', 'insensitive']) {
          if (a.has_style_pseudo_class(st)) continue;
          a.add_style_pseudo_class(st);
          a.ensure_style();
          const m = a.get_theme_node();
          out[path + '|' + st] = [col(m.get_background_color()), leaf(a) ? col(m.get_foreground_color()) : null,
                                  col(m.get_border_color(St.Side.TOP)), shadow(m)];
          // what the widget's own text inherits in that state
          leaves(a, path, (c, p) => { c.ensure_style(); out[p + '|' + st + ' (on ' + nm(a) + ')'] =
            [null, col(c.get_theme_node().get_foreground_color()), null, null]; });
          a.remove_style_pseudo_class(st);
          a.ensure_style();
          leaves(a, path, c => c.ensure_style());
        }
      }
    }
    a.get_children().forEach((c, i) => walk(c, path + ' > ' + nm(c) + '[' + i + ']', d + 1));
  };
  walk(ROOT, nm(ROOT), 0); return JSON.stringify(out); })()"""

# Each surface: how to open it, the actor to walk, how to close it. A
# surface that cannot be read fails the scan (its colors went unchecked),
# unless LEAKS_UNREADABLE names it with the reason.
SURFACES = [
    ("desktop-menu", "Main.layoutManager._bgManagers[0].backgroundActor._backgroundMenu.open(false)",
     "Main.layoutManager._bgManagers[0].backgroundActor._backgroundMenu.actor",
     "Main.layoutManager._bgManagers[0].backgroundActor._backgroundMenu.close(false)"),
    ("date-menu", "Main.panel.statusArea.dateMenu.menu.open(false)",
     "Main.panel.statusArea.dateMenu.menu.actor", "Main.panel.statusArea.dateMenu.menu.close(false)"),
    ("quick-settings", "Main.panel.statusArea.quickSettings.menu.open(false)",
     "Main.panel.statusArea.quickSettings.menu.actor", "Main.panel.statusArea.quickSettings.menu.close(false)"),
    ("quick-settings-submenu",
     "Main.panel.statusArea.quickSettings.menu.open(false); "
     "Main.panel.statusArea.quickSettings.menu._grid.get_children().find(c => c.menu && c.menuEnabled !== false)?.menu.open(false)",
     "Main.panel.statusArea.quickSettings.menu.actor", "Main.panel.statusArea.quickSettings.menu.close(false)"),
    ("app-grid", "Main.overview.showApps()", "Main.layoutManager.overviewGroup", "Main.overview.hide()"),
    ("app-icon-menu",
     "Main.overview.showApps(); const ad = Main.overview._overview.controls._appDisplay; "
     "(ad._orderedItems ?? []).find(i => i.popupMenu)?.popupMenu()",
     "Main.layoutManager.uiGroup", "Main.overview.hide()"),
    ("run-dialog", "Main.openRunDialog()", "Main.layoutManager.modalDialogGroup",
     "Main.layoutManager.modalDialogGroup.get_children().forEach(c => c.close?.() ?? c._dialog?.close?.())"),
    ("osd", "Main.osdWindowManager.showAll(new imports.gi.Gio.ThemedIcon({name: 'audio-volume-medium-symbolic'}), 'Volume', 0.5, 1)",
     "Main.layoutManager.uiGroup", "Main.osdWindowManager.hideAll()"),
    ("banner", "Main.notify('Pulsar leaks', 'a banner, to read its colors')", "Main.messageTray",
     "Main.messageTray.getSources().forEach(s => s.destroy())"),
    ("screenshot-ui", "Main.screenshotUI.open()", "Main.screenshotUI", "Main.screenshotUI.close(true)"),
    # needs the a11y screen-keyboard key on (leaks() sets it)
    ("keyboard", "Main.keyboard.open(Main.layoutManager.primaryIndex)", "Main.layoutManager.keyboardBox",
     "Main.keyboard.close(true)"),
    # a key's long-press popup (its extended keys)
    ("keyboard-subkeys",
     "Main.keyboard.open(Main.layoutManager.primaryIndex); imports.gi.GLib.timeout_add(0, 800, () => { "
     "const find = a => a._extendedKeys?.length ? a : a.get_children().map(find).find(Boolean); "
     "const k = find(Main.layoutManager.keyboardBox); if (k) { k._ensureExtendedKeysPopup(); k._showSubkeys(); "
     "globalThis.__sk = k; } return false; })",
     "globalThis.__sk._boxPointer", "globalThis.__sk?._hideSubkeys?.(); Main.keyboard.close(true)", 2.5),
    ("end-session",
     "const d = Main.layoutManager.modalDialogGroup.get_children().find(c => c.constructor.name === 'EndSessionDialog'); "
     "globalThis.__es = d; d.OpenAsync([2, 0, 60, []], {return_error_literal() {}, return_value() {}})",
     "Main.layoutManager.modalDialogGroup", "globalThis.__es?.close()", 2),
    ("polkit",
     "const c = Main.componentManager._allComponents.polkitAgent; "
     "c._onInitiate(null, 'org.pulsar.leaks', 'Authentication is required to read colors', '', 'leaks', "
     "[imports.gi.GLib.get_user_name()]); c._currentDialog._ensureOpen()",
     "Main.layoutManager.modalDialogGroup",
     "Main.componentManager._allComponents.polkitAgent._currentDialog?.close()", 2),
    ("keyring",
     "const k = Main.componentManager._allComponents.keyring; k._enabled = true; k.emit('new-prompt'); "
     "k._currentPrompt.message = 'Unlock the keyring'; k._currentPrompt.emit('show-password')",
     "Main.layoutManager.modalDialogGroup",
     "Main.layoutManager.modalDialogGroup.get_children().forEach(c => c.constructor.name === 'KeyringDialog' && c.close())"),
    ("run-dialog-error",
     "Main.openRunDialog(); Main.layoutManager.modalDialogGroup.get_children()"
     ".find(c => c.constructor.name === 'RunDialog')._showError('Command not found')",
     "Main.layoutManager.modalDialogGroup",
     "Main.layoutManager.modalDialogGroup.get_children().forEach(c => c.constructor.name === 'RunDialog' && c.close())"),
    ("app-folder",
     "Main.overview.showApps(); const ad = Main.overview._overview.controls._appDisplay; "
     "const f = (ad._orderedItems ?? []).find(i => i._folder); f._ensureFolderDialog(); f._dialog.popup()",
     "Main.layoutManager.overviewGroup", "Main.overview.hide()", 2),
    ("search-apps", "Main.overview.show(); Main.overview.searchEntry.set_text('settings')",
     "Main.layoutManager.overviewGroup", "Main.overview.searchEntry.set_text(''); Main.overview.hide()", 3),
    ("search-system",
     "import('resource:///org/gnome/shell/misc/systemActions.js').then(m => { "
     "for (const a of m.getDefault()._actions.values()) a.available = true; "
     "Main.overview.show(); Main.overview.searchEntry.set_text('power'); })",
     "Main.layoutManager.overviewGroup", "Main.overview.searchEntry.set_text(''); Main.overview.hide()", 3),
    # the window picker with every preview's caption and close button up,
    # the workspace thumbnails, and the dash with a label
    ("window-picker",
     "Main.overview.show(); imports.gi.GLib.timeout_add(0, 700, () => { const walk = a => { "
     "if (a.showOverlay && a.constructor.name === 'WindowPreview') a.showOverlay(false); "
     "a.get_children().forEach(walk); }; walk(Main.layoutManager.overviewGroup); "
     "Main.overview.dash._box.get_children().find(c => c.showLabel)?.showLabel(); return false; })",
     "Main.layoutManager.uiGroup", "Main.overview.hide()", 2.5),
    ("calendar-notification", "Main.notify('Pulsar leaks', 'a notification in the list'); "
     "Main.panel.statusArea.dateMenu.menu.open(false)",
     "Main.panel.statusArea.dateMenu.menu.actor",
     "Main.panel.statusArea.dateMenu.menu.close(false); Main.messageTray.getSources().forEach(s => s.destroy())", 2),
    ("panel-indicators",
     "for (const k of ['screenRecording', 'screenSharing', 'dwellClick', 'a11y', 'keyboard']) "
     "Main.panel.statusArea[k]?.show?.(); "
     "Main.panel.statusArea.quickSettings._indicators?.get_children().forEach(c => c.show())",
     "Main.panel", ""),
    ("input-source-menu", "Main.panel.statusArea.keyboard?.menu.open(false)",
     "Main.panel.statusArea.keyboard.menu.actor", "Main.panel.statusArea.keyboard?.menu.close(false)"),
    ("alt-tab",
     "import('resource:///org/gnome/shell/ui/altTab.js').then(m => { const p = new m.AppSwitcherPopup(); "
     "p._resetNoModsTimeout = () => {}; p.show(false, 'switch-applications', 0); p._showImmediately(); "
     "globalThis.__sw = p; })",
     "globalThis.__sw", "globalThis.__sw?.destroy()"),
    ("workspace-switcher",
     "import('resource:///org/gnome/shell/ui/workspaceSwitcherPopup.js').then(m => { "
     "const p = new m.WorkspaceSwitcherPopup(); p.display(1); "
     "if (p._timeoutId) { imports.gi.GLib.source_remove(p._timeoutId); p._timeoutId = 0; } globalThis.__ws = p; })",
     "globalThis.__ws", "globalThis.__ws?.destroy()"),
    ("window-menu",
     "import('resource:///org/gnome/shell/ui/windowMenu.js').then(m => { "
     "const w = global.get_window_actors().map(a => a.meta_window).find(w => w.get_window_type() === 0); "
     "const src = new imports.gi.St.Widget({width: 1, height: 1}); Main.layoutManager.uiGroup.add_child(src); "
     "src.set_position(400, 300); const menu = new m.WindowMenu(w, src); "
     "Main.layoutManager.uiGroup.add_child(menu.actor); menu.open(false); globalThis.__wm = menu; })",
     "globalThis.__wm.actor", "globalThis.__wm?.close(false); globalThis.__wm?.destroy()"),
    ("ibus-candidates",
     "const p = Main.layoutManager.uiGroup.get_children().find(c => c.constructor.name === 'IbusCandidatePopup'); "
     "globalThis.__cp = p; p._dummyCursor.set_position(500, 400); p._dummyCursor.set_size(1, 20); "
     "p._preeditText.text = 'pinyin'; p._preeditText.show(); p._auxText.text = 'aux'; p._auxText.show(); "
     "p._candidateArea.setCandidates(['1', '2', '3'], ['alpha', 'beta', 'gamma'], 1, true); "
     "p._candidateArea.show(); p._updateVisibility()",
     "globalThis.__cp", "globalThis.__cp?.close(0)"),
    ("osd-overdrive",
     "Main.osdWindowManager.showAll(new imports.gi.Gio.ThemedIcon({name: 'audio-volume-overamplified-symbolic'}), "
     "'Volume', 1.3, 1.5)", "Main.layoutManager.uiGroup", "Main.osdWindowManager.hideAll()"),
    ("resize-popup",
     "Main.wm._showResizePopup(global.display, true, new imports.gi.Mtk.Rectangle({x: 200, y: 200, width: 600, "
     "height: 400}), 80, 24)", "Main.wm._resizePopup", "Main.wm._showResizePopup(global.display, false)"),
] + [
    # every quick settings submenu (network, bluetooth, power, audio output...)
    (f"quick-settings-menu-{i}",
     "const qs = Main.panel.statusArea.quickSettings.menu; qs.open(false); "
     f"qs._grid.get_children().filter(c => c.menu && c.menuEnabled !== false)[{i}]?.menu.open(false)",
     "Main.panel.statusArea.quickSettings.menu.actor", "Main.panel.statusArea.quickSettings.menu.close(false)")
    for i in range(8)
] + [
    # a banner of each urgency that shows one (a low one never does; a
    # critical one is lit in the theme's red)
    (f"banner-{u.lower()}",
     "import('resource:///org/gnome/shell/ui/messageTray.js').then(m => { "
     "const src = new m.Source({title: 'Pulsar leaks'}); Main.messageTray.add(src); "
     f"src.addNotification(new m.Notification({{source: src, title: '{u}', body: 'a banner', "
     f"urgency: m.Urgency.{u}}})); }})",
     "Main.messageTray", "Main.messageTray.getSources().forEach(s => s.destroy())", 2)
    for u in ("NORMAL", "HIGH", "CRITICAL")
]


# Surfaces a scan may fail to read, each with why: nothing else may.
LEAKS_UNREADABLE = [
]


def scan(tag):
    """Every surface's widget states under the current theme, and the
    surfaces that could not be read: (states, notes, unread)."""
    got, notes, unread = {}, [], []
    for name, opener, root, closer, *wait in SURFACES:
        eval_js(f"try {{ {opener}; }} catch (e) {{}} 1")
        time.sleep(wait[0] if wait else 1.2)
        ok, raw = eval_js(WALK.replace("ROOT", root))
        eval_js(f"try {{ {closer}; }} catch (e) {{}} 1")
        time.sleep(0.6)
        try:
            data = json.loads(raw.encode().decode("unicode_escape").replace('\\"', '"').strip('"')) if ok else None
        except Exception:
            data = None
        if not data:
            allowed = [why for pat, why in LEAKS_UNREADABLE if re.fullmatch(pat, name)]
            line = f"{tag}: {name} could not be read ({raw[:120]})"
            (notes if allowed else unread).append(line + (f" -- allowed: {allowed[0]}" if allowed else ""))
            continue
        for k, v in data.items():
            got[f"{name}: {k}"] = v
    return got, notes, unread


# Every quick toggle, forced checked: what its ground resolves to. A leak fix
# must never cost an accent-filled state (1a704c7 briefly made every checked
# toggle an 18% grey wash: a generated `.button:checked` came after
# `.quick-toggle:checked` at the same specificity).
CHECKED = r"""(() => { const out = []; const walk = a => {
  if (a.has_style_class_name?.('quick-toggle') && a.is_mapped()) {
    const had = a.has_style_pseudo_class('checked');
    if (!had) a.add_style_pseudo_class('checked');
    a.ensure_style();
    const c = a.get_theme_node().get_background_color();
    out.push('#' + [c.red, c.green, c.blue].map(v => v.toString(16).padStart(2, '0')).join(''));
    if (!had) { a.remove_style_pseudo_class('checked'); a.ensure_style(); }
  }
  a.get_children().forEach(walk); };
  walk(Main.panel.statusArea.quickSettings.menu.actor); return JSON.stringify(out); })()"""


def checked_toggles(slug, mode):
    """Quick toggles that do not resolve to the theme's accent when checked."""
    eval_js("Main.panel.statusArea.quickSettings.menu.open(false)")
    time.sleep(1.2)
    ok, raw = eval_js(CHECKED)
    eval_js("Main.panel.statusArea.quickSettings.menu.close(false)")
    got = json.loads(raw.encode().decode("unicode_escape").replace('\\"', '"').strip('"')) if ok else []
    want = palette(slug, mode)["accent"].lower()
    if not got:
        return [f"{slug}/{mode}: no quick toggles found to check"]
    return [f"{slug}/{mode}: checked quick toggle is {g}, want the accent {want}"
            for g in got if not close(g, want, 3)]


def neutral(prop, color):
    """Not the theme's to set: no color at all, a translucent white or black
    wash (reads as a neutral tint on any theme, as the sheet's own washes do;
    stock_states.py draws the same line), any black or white shadow, and an
    opaque white or black ground (a knob, a scrim). Opaque white text or
    edges are NOT neutral: that is stock's text on its own dark grounds."""
    if color is None:
        return True
    r, g, b, a = (int(x) for x in color.split(","))
    bw = (r, g, b) in ((0, 0, 0), (255, 255, 255))
    return bw and (a < 255 or prop in ("shadow", "background"))


# Stock left as stock on purpose, by the widget path it shows up under.
LEAKS_ALLOW = [
    (r"screenshot-ui-area-indicator", "the screenshot selection's white frame and black shade, over any capture"),
    (r"screen-recording-indicator|screen-sharing-indicator",
     "the recording and screen-sharing pills: GNOME's own alarm red and orange"),
]


def leaks():
    """Colors that stay the same under two unrelated themes did not come from
    the theme: stock showing through. Walk each surface in every state and
    report what does not move, two ways:

      Gruvbox light vs Nord dark: stock's own fixed colors.
      Alucard (a light-only theme) with the system scheme dark vs Nord dark:
        the same stock sheet under both, so a color stock takes from its
        scheme (and which the first pair sees move with the sheet) stays put
        here, and would be stock's dark value on a light theme."""
    for k in ("glass", "window-glass", "lighting"):
        dconf(f"/org/gnome/shell/extensions/pulsar-theme/{k}", "true")
    dconf("/org/gnome/desktop/interface/enable-animations", "false")
    dconf("/org/gnome/desktop/a11y/applications/screen-keyboard-enabled", "true")
    # two input sources, so the keyboard indicator and its menu exist
    dconf("/org/gnome/desktop/input-sources/sources", "[('xkb', 'us'), ('xkb', 'de')]")
    start_shell()
    # windows for Alt+Tab, the window picker and the window menu
    launch_apps()
    time.sleep(3)
    runs, notes, accent, unread = {}, [], [], []
    for slug, mode, scheme in (("gruvbox", "light", "default"), ("nord", "dark", "prefer-dark"),
                               ("alucard", "light", "prefer-dark")):
        pt("set", slug, "--no-restart")
        dconf("/org/gnome/desktop/interface/color-scheme", f"'{scheme}'")
        time.sleep(2)
        got, n, u = scan(f"{slug}-{scheme}")
        runs[slug] = got
        notes += n
        unread += u
        accent += checked_toggles(slug, mode)
    found = []
    for pair, (x, y) in (("fixed", ("gruvbox", "nord")), ("scheme", ("alucard", "nord"))):
        a, b = runs[x], runs[y]
        for k in sorted(set(a) & set(b)):
            for i, prop in enumerate(("background", "color", "border", "shadow")):
                va, vb = (a[k] + [None])[i], (b[k] + [None])[i]
                if va == vb and not neutral(prop, va):
                    surface, rest = k.split(": ", 1)
                    path, state = rest.rsplit("|", 1)
                    if any(re.search(pat, path) for pat, _ in LEAKS_ALLOW):
                        continue
                    found.append({"pair": pair, "surface": surface, "path": path, "state": state or "rest",
                                  "property": prop, "color": va})
    compared = len(set(runs["gruvbox"]) & set(runs["nord"])) + len(set(runs["alucard"]) & set(runs["nord"]))
    stop_shell()
    logged = shell_log_problems("leaks")
    ok = not (found or accent or unread or logged)
    report = {"ok": ok, "compared": compared, "leaks": found, "accent": accent, "unreadable": unread,
              "shell_log": logged, "notes": notes}
    SHOTS.mkdir(exist_ok=True)
    (SHOTS / "leaks-report.json").write_text(json.dumps(report, indent=1))
    print(f"compared {compared} widget states; {len(found)} colors did not move", flush=True)
    for n in notes:
        print("  note:", n)
    print(f"surfaces that could not be read: {len(unread)}", flush=True)
    for x in unread:
        print("  ", x)
    print(f"checked quick toggles off the accent: {len(accent)}", flush=True)
    for x in accent:
        print("  ", x)
    print(f"pulsar-theme warnings and JS errors in the Shell log: {len(logged)}", flush=True)
    for x in logged[:10]:
        print("  ", x)
    print(f"LEAKS {'PASS' if ok else 'FAIL'}", flush=True)
    return 0 if ok else 1


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "gate"
    rc = 0
    try:
        rc = {"gate": lambda: gate(sys.argv[2:]), "firstlogin": firstlogin, "restart": restart,
              "picker": picker, "desktops": lambda: desktops(sys.argv[2:]), "glass": glass,
              "leaks": leaks}[mode]() or 0
    finally:
        kill_apps()
        for p in procs:
            p.terminate()
        LOG.flush()
    sys.exit(rc)


if __name__ == "__main__":
    main()
