#!/usr/bin/env python3
"""Render each theme's wallpapers from assets/shaders/theme.frag.

Every [[wallpaper.render]] table in themes/<slug>/theme.toml is one PNG:

  [[wallpaper.render]]
  variant = "dark"            # which palette drives it
  look = "silk"               # silk | leak | satin | holo  (Pulsar's four looks)
  c1 = "magenta"              # lights: palette key, "#hex", or "a~b@t" (OKLab mix)
  c2 = "blue"
  c3 = "cyan"
  seed = [3.1, -1.2]          # composition knobs; see theme.frag for the rest

Output: system_files/usr/share/pulsar/themes/<slug>/backgrounds/<look>-<variant>.png
(gitignored, like the brand renders), which the Containerfile converts to
JPEG XL; theme.toml already names the .jxl. `--sheet` also writes
.preview/theme-wallpapers.png, every render with a mock top bar and
quick-settings card on it, so a review is of the wallpaper AS A DESKTOP.

Headless (EGL + llvmpipe), same environment as scripts/render-wallpapers.py:
scripts/build.sh runs both before the image build.

  python3 scripts/render-theme-wallpapers.py [--only slug] [--preview] [--sheet]
"""
import argparse
import os
import pathlib
import sys
from importlib.machinery import SourceFileLoader

os.environ.setdefault("PYOPENGL_PLATFORM", "egl")
REPO = pathlib.Path(__file__).resolve().parent.parent
pt = SourceFileLoader("pulsar_theme", str(REPO / "scripts" / "pulsar-theme")).load_module()
SHADER = (REPO / "assets" / "shaders" / "theme.frag").read_text()
THEMES = REPO / "system_files" / "usr" / "share" / "pulsar" / "themes"
PREVIEW = REPO / ".preview"
LOOKS = {"silk": 0.0, "leak": 1.0, "satin": 2.0, "holo": 3.0}
PREAMBLE = "#version 330 core\nout vec4 _o;\n#define gl_FragColor _o\n"
VERTEX = "#version 330 core\nin vec2 in_pos;\nvoid main(){gl_Position=vec4(in_pos,0.0,1.0);}\n"

DEFAULTS = dict(desat=0.18, gain=1.0, stars=1.0, down=0.17, wash=0.35, fold=2.2,
                seed=[0.0, 0.0], dir=[-0.8, -0.6], bloom=[0.42, -0.06], beam=-0.35, time=0.0, quiet=1.0)


def color(v, spec):
    """'blue', '#aabbcc', or 'a~b@t' (t of the way from a to b, in OKLab)."""
    spec = spec.strip()
    if "~" in spec:
        a, rest = spec.split("~", 1)
        b, t = rest.rsplit("@", 1)
        ca, cb, t = color(v, a), color(v, b), float(t)
        la, lb = ca.oklab(), cb.oklab()
        return from_oklab([x + (y - x) * t for x, y in zip(la, lb)])
    if spec.startswith("#"):
        return pt.Color.parse(spec)
    if spec in ("white", "black"):
        return pt.WHITE if spec == "white" else pt.BLACK
    return v[spec]


def from_oklab(L):
    l_ = L[0] + 0.3963377774 * L[1] + 0.2158037573 * L[2]
    m_ = L[0] - 0.1055613458 * L[1] - 0.0638541728 * L[2]
    s_ = L[0] - 0.0894841775 * L[1] - 1.2914855480 * L[2]
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    lin = (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
           -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
           -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    f = lambda c: 12.92 * c if c <= 0.0031308 else 1.055 * max(c, 0) ** (1 / 2.4) - 0.055
    return pt.Color(*(f(c) for c in lin))


def uniforms(theme, spec):
    v = theme.variants[spec["variant"]]
    s = {**DEFAULTS, **spec}
    dark = spec["variant"] == "dark"
    rgb = lambda c: (c.r, c.g, c.b)
    u = {
        "u_theme": 0.0 if dark else 1.0,
        "u_look": LOOKS[s["look"]],
        "u_time": float(s["time"]),
        "u_c1": rgb(color(v, s.get("c1", "magenta"))),
        "u_c2": rgb(color(v, s.get("c2", "blue"))),
        "u_c3": rgb(color(v, s.get("c3", "accent"))),
        "u_c4": rgb(color(v, s.get("c4", s.get("c2", "blue")))),
        "u_star": rgb(color(v, s.get("star", "foreground_bright"))),
        # night: the ground IS the theme's deepest surface, so the top bar
        # (background_deep) grows out of the wallpaper instead of sitting on it
        "u_ga": rgb(color(v, s.get("ground_far", "background_deep~black@0.62"))),
        "u_gb": rgb(color(v, s.get("ground_near", "background_deep~black@0.3"))),
        # dawn: the theme's own paper, a step darker toward the top
        "u_da": rgb(color(v, s.get("dawn_bottom", "background"))),
        "u_db": rgb(color(v, s.get("dawn_top", "background~muted@0.16"))),
    }
    for k in ("desat", "gain", "stars", "down", "wash", "fold", "beam", "quiet"):
        u["u_" + k] = float(s[k])
    for k in ("seed", "dir", "bloom"):
        u["u_" + k] = tuple(float(x) for x in s[k])
    return u


def render(ctx, prog, vao, w, h, u):
    import numpy as np
    from PIL import Image
    prog["u_resolution"].value = (float(w), float(h))
    for k, val in u.items():
        if k in prog:
            prog[k].value = val
    fbo = ctx.simple_framebuffer((w, h), components=3)
    fbo.use()
    fbo.clear(0, 0, 0)
    vao.render()
    img = Image.frombytes("RGB", (w, h), fbo.read(components=3)).transpose(Image.FLIP_TOP_BOTTOM)
    fbo.release()
    return img


def mock_ui(tile, v, scale):
    """Top bar + quick-settings card, in the theme's own shell colours."""
    from PIL import ImageDraw
    d = ImageDraw.Draw(tile, "RGBA")
    W, H = tile.size
    bar = round(32 * scale)
    c = lambda k, a=255: tuple(round(x * 255) for x in (v[k].r, v[k].g, v[k].b)) + (a,)
    d.rectangle([0, 0, W, bar], fill=c("background_deep"))
    d.text((W // 2 - 18, bar // 2 - 5), "12:00", fill=c("foreground"))
    x0, y0 = W - round(400 * scale), bar + round(6 * scale)
    d.rounded_rectangle([x0, y0, W - round(8 * scale), y0 + round(150 * scale)], radius=round(28 * scale), fill=c("popover", 245))
    bw = round(170 * scale)
    d.rounded_rectangle([x0 + 14, y0 + round(60 * scale), x0 + 14 + bw, y0 + round(100 * scale)], radius=99, fill=c("accent"))
    d.rounded_rectangle([x0 + 24 + bw, y0 + round(60 * scale), x0 + 24 + 2 * bw, y0 + round(100 * scale)], radius=99,
                        fill=c("foreground", 30))


def contact_sheet(entries, out):
    from PIL import Image, ImageDraw
    tw, th = 480, 300
    by_theme = {}
    for theme, spec, path in entries:
        by_theme.setdefault(theme.slug, (theme, []))[1].append((spec, path))
    cols = max(len(x[1]) for x in by_theme.values())
    pad, label = 14, 26
    sheet = Image.new("RGB", (pad + cols * (tw + pad), pad + len(by_theme) * (th + label + pad)), (18, 18, 20))
    d = ImageDraw.Draw(sheet)
    for row, (slug, (theme, items)) in enumerate(sorted(by_theme.items())):
        y = pad + row * (th + label + pad)
        for col, (spec, path) in enumerate(sorted(items, key=lambda x: (x[0]["look"] != items[0][0]["look"], x[0]["variant"]))):
            x = pad + col * (tw + pad)
            tile = Image.open(path).convert("RGB").resize((tw, th), Image.LANCZOS)
            mock_ui(tile, theme.variants[spec["variant"]], tw / 2560 * 1.6)
            sheet.paste(tile, (x, y + label))
            d.text((x, y + 6), f"{theme.name} - {spec['look']} {spec['variant']}", fill=(220, 220, 225))
    sheet.save(out, optimize=True)
    print(f"contact sheet: {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append")
    ap.add_argument("--width", type=int, default=2560)
    ap.add_argument("--height", type=int, default=1600)
    ap.add_argument("--preview", action="store_true", help="640x400 into .preview/themes/, for tuning")
    ap.add_argument("--sheet", action="store_true", help="also write .preview/theme-wallpapers.png")
    ap.add_argument("--sheet-only", action="store_true")
    a = ap.parse_args()
    import moderngl
    import numpy as np
    w, h = (640, 400) if a.preview else (a.width, a.height)
    ctx = moderngl.create_standalone_context(backend="egl")
    prog = ctx.program(vertex_shader=VERTEX, fragment_shader=PREAMBLE + SHADER)
    vao = ctx.simple_vertex_array(prog, ctx.buffer(np.array([-1, -1, 3, -1, -1, 3], dtype="f4")), "in_pos")
    entries = []
    for tt in sorted(THEMES.glob("*/theme.toml")):
        theme = pt.Theme(tt)
        specs = theme.raw.get("wallpaper", {}).get("render", [])
        if not specs or (a.only and theme.slug not in a.only):
            continue
        for spec in specs:
            dest = (PREVIEW / "themes" / f"{theme.slug}-{spec['look']}-{spec['variant']}.png") if a.preview \
                else theme.dir / "backgrounds" / f"{spec['look']}-{spec['variant']}.png"
            if not a.sheet_only:
                dest.parent.mkdir(parents=True, exist_ok=True)
                render(ctx, prog, vao, w, h, uniforms(theme, spec)).save(dest, optimize=not a.preview)
                print(f"  {dest.relative_to(REPO)}", flush=True)
            entries.append((theme, spec, dest))
    if entries and (a.sheet or a.sheet_only or a.preview):
        PREVIEW.mkdir(exist_ok=True)
        contact_sheet(entries, PREVIEW / "theme-wallpapers.png")
    if not entries:
        sys.exit("no [[wallpaper.render]] tables found under " + str(THEMES))


if __name__ == "__main__":
    sys.exit(main())
