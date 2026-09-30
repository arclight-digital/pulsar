#!/usr/bin/python3
"""Stock-grey leaks in the Shell sheet, found without a running Shell.

Stock GNOME paints its controls in its own fixed greys (#36363a and friends),
chosen to sit on its own grey menus. The theme recolors those menus, so every
stock selector that paints a solid grey and that the theme's Shell sheet
(templates/gnome-shell.css) does not restate shows as a grey slab on a themed
surface -- the desktop menu's items under the pointer, before 95d1442. It
leaks two ways: a control the sheet never names, and a state of one it does
(`.button:active:hover` is longer than the sheet's `.button:active`, and a
longer selector wins whatever order the sheets load in).

The fix is to name each such selector at stock's own specificity; the theme's
sheet loads after stock's, so an equal selector wins on order. This script
finds them and writes them:

  stock_states.py check [stock.css...]   exit 1 and list every unnamed state
  stock_states.py emit  [stock.css...]   print the generated block for the
                                         template (between the markers, which
                                         open the sheet: see the block's comment)

With no stock.css given it reads the dark and light sheets out of this
machine's gnome-shell-theme.gresource (or the host's, from a toolbox, or
$PULSAR_STOCK_GRESOURCE); exit 77 when there is none (a build
host without GNOME Shell), which the bats test turns into a skip.

Only states whose stock background carries a solid color other than white
or black count: a pure accent value is themed already (the engine sets GNOME's
accent), and a transparent white or black wash reads as a neutral tint on any
theme, as the theme's own washes do.
"""
import os
import pathlib
import re
import sys

TEMPLATE = pathlib.Path(__file__).resolve().parents[2] / \
    "system_files/usr/share/pulsar/theme/templates/gnome-shell.css"
# this machine's, the host's from inside a toolbox, or one named outright
GRESOURCES = [os.environ.get("PULSAR_STOCK_GRESOURCE", ""),
              "/usr/share/gnome-shell/gnome-shell-theme.gresource",
              "/run/host/usr/share/gnome-shell/gnome-shell-theme.gresource"]
BEGIN = "/* BEGIN stock states (tests/theme-gate/stock_states.py emit) */"
END = "/* END stock states */"

STATE = re.compile(r":(hover|focus|active|checked|selected|insensitive|highlighted|drop)\b")
PSEUDO = re.compile(r":[a-z-]+(\([^)]*\))?")

# What each family's states become, as the template's own washes. Families
# are matched in order, first match wins; a selector nobody claims is an
# error, so a new control in a new GNOME is a decision, not a silent default.
WASH = "rgba({{foreground_rgb}}, %s)"
# Stock left as stock on purpose: surfaces the theme never reaches, or does
# not own. Each needs a reason; anything else a GNOME release adds fails the
# check until it is themed or listed here.
ALLOW = [
    (r"#LookingGlass|\.lg-", "Looking Glass: the developer console, stock by design"),
    (r"login-dialog|unlock-dialog|#lockDialogGroup",
     "the login and lock screens: extensions do not run there, so neither does the theme"),
    (r"parental-controls-shield",
     "the parental-controls shield: it stands in for the unlock prompt (gdm/authPrompt.js), on the lock screen"),
    (r"\.toggle-switch \.handle", "the switch knob: a near-white disc in both schemes, as libadwaita's"),
]

FAMILIES = [
    # accent-filled at rest: they stay accent in every state
    ("accent", re.compile(r"\.calendar-today|\.button\.default|\.keyboard-brightness-level \.button:.*checked|"
                          r"\.quick-toggle(-has-menu)?\b.*:checked"),
     {"rest": "{{accent}}", "hover": "{{accent_hover}}", "press": "{{accent}}"}),
    # the ground between workspaces while they slide, and the on-screen
    # keyboard's tray
    ("deep", re.compile(r"^\.workspace-animation|^#keyboard$"), {"rest": "{{background_deep}}"}),
    # the on-screen keyboard's keys, lifted off its tray as a popover is off
    # the desktop (raised is too close to deep on a light theme to read as a
    # key); its modifier keys (shift, enter) a step below the letters, as
    # stock's are
    ("modifier-key", re.compile(r"^\.keyboard-key\.default-key"),
     {"rest": "{{background}}",
      "hover": "st-mix({{foreground}}, {{background}}, 8%)",
      "press": "st-mix({{foreground}}, {{background}}, 14%)"}),
    ("key", re.compile(r"^\.keyboard-key"),
     {"rest": "{{popover}}",
      "hover": "st-mix({{foreground}}, {{popover}}, 8%)",
      "press": "st-mix({{foreground}}, {{popover}}, 14%)"}),
    # a submenu's own ground inside a menu: a faint lift, as a card is
    ("submenu", re.compile(r"^\.popup-sub-menu$"), {"rest": WASH % "0.05"}),
    ("scrollbar", re.compile(r"StScrollBar"),
     {"rest": WASH % "0.3", "hover": WASH % "0.5", "press": WASH % "0.4"}),
    # the app grid's page dots
    ("dot", re.compile(r"\.page-indicator-icon"), {"rest": "{{foreground}}"}),
    # surfaces that sit on a popover as a raised card
    ("card", re.compile(r"^\.(message|events-button|world-clocks-button|weather-button|calendar|quick-toggle-menu)(:|$)"),
     {"rest": "{{background_raised}}",
      "hover": "st-mix({{foreground}}, {{background_raised}}, 6%)",
      "press": "st-mix({{foreground}}, {{background_raised}}, 10%)"}),
    # controls that are a faint foreground lift at rest
    ("raised", re.compile(r"^\.(button|icon-button|notification-button|app-folder|page-navigation-arrow)(:|$)|"
                          r"\.icon-button(?![.\w-])|\.page-navigation-arrow|"
                          r"\.modal-dialog-button|\.quick-toggle-menu-button|"
                          r"(?<!\.flat)\.message-(expand|close|collapse)-button|"
                          r"(?<!\.flat)\.screenshot-ui-show-pointer-button"),
     {"rest": WASH % "0.08", "hover": WASH % "0.13", "press": WASH % "0.18"}),
    # text fields: StEntry's own steps
    ("entry", re.compile(r"\.search-entry|\.folder-name-entry"),
     {"rest": WASH % "0.08", "hover": WASH % "0.11", "press": WASH % "0.11"}),
    # everything flat at rest: calendar cells, flat buttons, tiles, list rows
    ("flat", re.compile(r"\.calendar|\.flat|\.overview-tile|\.grid-search-result|\.list-search-result|"
                        r"\.search-provider-icon|\.switcher-list|\.audio-selection-device|"
                        r"\.popup-menu-item|\.datemenu-today-button|\.overview-icon|\.candidate-box|"
                        r"\.slider-bin|\.screenshot-ui-type-button|\.word-suggestions"),
     {"rest": "transparent", "hover": WASH % "0.08", "press": WASH % "0.14"}),
]


def rules(css):
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    out = []
    for m in re.finditer(r"([^{}@;]+)\{([^{}]*)\}", css):
        sels = [re.sub(r"\s+", " ", s).strip() for s in m.group(1).split(",")]
        decls = {}
        for d in m.group(2).split(";"):
            if ":" in d:
                k, v = d.split(":", 1)
                decls[k.strip()] = v.strip()
        out.append((sels, decls))
    return out


def solid_grey(value):
    """A stock value that paints its own color: a hex other than white/black."""
    return any(h.lower() not in ("#ffffff", "#fff", "#000000", "#000")
               for h in re.findall(r"#[0-9a-fA-F]{3,8}\b", value))


def level(sel, fam=None):
    s = set(STATE.findall(sel))
    # for an accent control :checked is simply "on", its resting look
    if fam == "accent":
        s.discard("checked")
    if s & {"active", "checked", "selected"}:
        return "press"
    if s & {"hover", "highlighted", "drop"}:
        return "hover"
    return "rest"   # focus alone, insensitive: the resting color


def family(sel):
    for name, pat, colors in FAMILIES:
        if pat.search(sel):
            return name, colors
    return None, None


def template_selectors(text):
    """The selectors the sheet gives a background of its own -- a rule that
    names one only for its text color leaves stock's grey behind it. The
    generated block counts, the rest of the sheet too."""
    tpl = re.sub(r"\{\{[^}]*\}\}", "#000", text)
    return {s for sels, d in rules(tpl) if "background-color" in d or "background" in d for s in sels}


def allowed(sel):
    return next((why for pat, why in ALLOW if re.search(pat, sel)), None)


def leaks(stock_sheets, template_text):
    named = template_selectors(template_text)
    found = {}
    for css in stock_sheets:
        for sels, decls in rules(css):
            bg = decls.get("background-color") or decls.get("background") or ""
            if not solid_grey(bg):
                continue
            for s in sels:
                if s in named or allowed(s):
                    continue
                found.setdefault(s, bg)
    return found


def stock_from_gresource():
    path = next((p for p in GRESOURCES if p and pathlib.Path(p).exists()), None)
    if not path:
        return None
    names = [f"/org/gnome/shell/theme/gnome-shell-{m}.css" for m in ("dark", "light")]
    try:
        import gi
        gi.require_version("Gio", "2.0")
        from gi.repository import Gio
        res = Gio.Resource.load(path)
        return [res.lookup_data(n, 0).get_data().decode() for n in names]
    except (ImportError, AttributeError, ValueError):
        # no PyGObject (a toolbox): glib's own tool reads the same file
        import subprocess
        return [subprocess.run(["gresource", "extract", path, n], capture_output=True,
                               text=True, check=True).stdout for n in names]


def without_block(text):
    if BEGIN in text:
        return text[:text.index(BEGIN)] + text[text.index(END) + len(END):]
    return text


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    sheets = [pathlib.Path(p).read_text() for p in sys.argv[2:]] or stock_from_gresource()
    if sheets is None:
        print("no gnome-shell-theme.gresource here; nothing to compare against", file=sys.stderr)
        return 77
    template = TEMPLATE.read_text()
    if mode == "check":
        found = leaks(sheets, template)
        for s, v in sorted(found.items()):
            print(f"{s}  <- stock {v}")
        if found:
            print(f"{len(found)} stock state(s) keep stock's grey; run `{sys.argv[0]} emit` "
                  f"and replace the block between the markers in {TEMPLATE.name}", file=sys.stderr)
        return 1 if found else 0
    if mode == "emit":
        # emitted against the sheet without the old block, so a rerun is stable
        found = leaks(sheets, without_block(template))
        groups, orphans = {}, []
        for s in sorted(found):
            name, colors = family(s)
            if not name:
                orphans.append(s)
                continue
            lv = level(s, name)
            # a family with one color keeps it in every state
            groups.setdefault((name, lv), (colors.get(lv, colors["rest"]), []))[1].append(s)
        if orphans:
            print("no family claims these; add one to FAMILIES:\n  " + "\n  ".join(orphans), file=sys.stderr)
            return 1
        order = [(f, lv) for f, _, _ in FAMILIES for lv in ("rest", "hover", "press")]
        print(BEGIN)
        print("/* Every selector stock paints in its own grey, restated at stock's own\n"
              "   specificity: this sheet loads after stock's, so each wins on order. First\n"
              "   in the sheet on purpose -- every hand-written rule below wins a tie with\n"
              "   these (a checked quick toggle is also a .button, and stays the accent).\n"
              "   Generated: edit FAMILIES in the script, not these lines. */")
        for key in order:
            if key not in groups:
                continue
            color, sels = groups[key]
            print(",\n".join(sels) + f" {{\n  background-color: {color}; }}")
        print(END)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
