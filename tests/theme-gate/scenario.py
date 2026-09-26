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
LOG = open("/tmp/harness-shell.log", "w")
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


def start_shell():
    if not IMAGE:
        home = pathlib.Path(os.environ["HOME"])
        ext = home / ".local/share/gnome-shell/extensions"
        ext.mkdir(parents=True, exist_ok=True)
        for src in [GATE / "gate-harness@local"]:
            shutil.copytree(src, ext / src.name, dirs_exist_ok=True)
        dconf("/org/gnome/shell/enabled-extensions", f"['gamescale@arclight.digital', '{EXT}', 'gate-harness@local']")
        dconf("/org/gnome/shell/welcome-dialog-last-shown-version", "'999'")
        dconf("/org/gnome/desktop/interface/enable-animations", "false")
    p = subprocess.Popen(["gnome-shell", "--headless", "--wayland", "--no-x11", "--virtual-monitor", f"{W}x{H}"],
                         stdout=LOG, stderr=LOG)
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


SAMPLE = GATE / "sample.py"
TOP = 32
APPS = {
    "org.gnome.TextEditor": (["gnome-text-editor", "--standalone", str(SAMPLE)], (0, 0, .43, .5)),
    "org.gnome.Ptyxis": (["ptyxis", "--new-window", "--", "btop"], (0, .5, .43, .5)),
    "org.gnome.Adwaita1.Demo": (["adwaita-1-demo"], (.43, 0, .57, .5)),
    "gtk3-widget-factory": (["gtk3-widget-factory"], (.43, .5, .57, .5)),
}


def cell(cls):
    x, y, w, h = APPS[cls][1]
    ah = H - TOP
    return round(x * W) + 5, TOP + round(y * ah) + 5, round(w * W) - 10, round(h * ah) - 10


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
        subprocess.run(["pkill", "-x", name], capture_output=True)
    time.sleep(0.8)


def pt(*args, check=True):
    r = subprocess.run(PT + list(args), text=True, capture_output=True, env=ENV)
    if check and r.returncode:
        print(r.stdout, r.stderr)
        raise SystemExit(f"pulsar-theme {' '.join(args)} failed")
    return r


def quick_settings(name):
    eval_js("global.get_window_actors().forEach(a => a.meta_window.minimize()); 1")
    time.sleep(0.8)
    eval_js("Main.panel.statusArea.quickSettings.menu.open(false)")
    time.sleep(1.0)
    ok, box = eval_js("(() => { const out = []; const walk = a => { if (a.has_style_class_name?.('quick-toggle') && a.checked && a.is_mapped()) "
                      "{ const [x, y] = a.get_transformed_position(); out.push([x, y, a.width, a.height]); } "
                      "a.get_children().forEach(walk); }; walk(Main.panel.statusArea.quickSettings.menu.actor); "
                      "return JSON.stringify(out); })()")
    png = screenshot(name)
    eval_js("Main.panel.statusArea.quickSettings.menu.close(false)")
    try:
        return png, json.loads(box.replace('\\"', '"').strip('"'))
    except Exception:
        return png, []


def theme_list():
    out = {}
    for ln in pt("list").stdout.splitlines():
        slug = ln[2:].split()[0]
        m = re.search(r"\[([a-z+]+)\]\s*$", ln)
        out[slug] = m.group(1).split("+") if m else ["dark"]
    return out


def palette(slug, mode):
    code = ("import json, importlib.machinery as M, importlib.util as U; "
            f"ld=M.SourceFileLoader('pt','{PT[0]}'); pt=U.module_from_spec(U.spec_from_loader('pt', ld)); "
            "ld.exec_module(pt); "
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
    for sel in re.findall(r"([^{}]+)\{", tpl):
        for tok in re.findall(r"[.#][A-Za-z][\w-]*", sel):
            if not re.search(re.escape(tok) + r"(?![\w-])", stock):
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
            qs, boxes = quick_settings(f"{slug}-{mode}-quicksettings")
            ex, ey, ew, eh = cell("org.gnome.TextEditor")
            ax, ay, aw, ah = cell("org.gnome.Adwaita1.Demo")
            probes = {"top bar = background_deep": (pixel(qs, W * 0.30, 6), [pal["background_deep"]]),
                      "Text Editor view = background": (pixel(desk, ex + ew * 0.85, ey + eh * 0.9), [pal["background"]]),
                      "libadwaita content = window|view": (pixel(desk, ax + aw * 0.95, ay + ah * 0.93),
                                                            [pal["window"], pal["view"]])}
            boxes = [b for b in boxes if all(isinstance(x, (int, float)) for x in b) and b[2] > 20]
            if boxes:
                bx, by, bw, bh = boxes[0]
                probes["checked quick toggle = accent"] = (pixel(qs, bx + bw * 0.93, by + bh / 2), [pal["accent"]])
            res = {k: {"ok": any(close(seen, w) for w in want), "seen": seen, "want": want}
                   for k, (seen, want) in probes.items()}
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

    report["ok"] = all(c["ok"] for c in report["checks"])
    (SHOTS / "gate-report.json").write_text(json.dumps(report, indent=1))
    print("\n".join(f"{'PASS' if c['ok'] else 'FAIL'}  {c['check']}" + (f"  -- {c['detail']}" if c["detail"] else "")
                    for c in report["checks"]))
    print(f"GATE {'PASS' if report['ok'] else 'FAIL'} on {report['gnome_shell']}")
    return 0 if report["ok"] else 1


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


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "gate"
    rc = 0
    try:
        rc = {"gate": lambda: gate(sys.argv[2:]), "firstlogin": firstlogin, "restart": restart,
              "picker": picker}[mode]() or 0
    finally:
        kill_apps()
        for p in procs:
            p.terminate()
        LOG.flush()
    sys.exit(rc)


if __name__ == "__main__":
    main()
