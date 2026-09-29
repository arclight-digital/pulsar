#!/usr/bin/env python3
"""Render each theme's wallpapers from assets/shaders/theme.frag.

Every [[wallpaper.render]] table in themes/<slug>/theme.toml is one PNG:

  [[wallpaper.render]]
  variant = "dark"            # which palette drives it
  look = "silk"               # silk leak satin holo relief tide orbit beacon (looks/looks.json)
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
import hashlib
import json
import os
import pathlib
import sys



os.environ.setdefault("PYOPENGL_PLATFORM", "egl")
REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import pulsar_theme_engine  # noqa: E402

pt = pulsar_theme_engine.load()
SHADERS = REPO / "assets" / "shaders"


def shader_source():
    """theme.frag, then every look file in looks/looks.json's order -- the
    shader as it compiles (render-wallpapers.py and the site assemble theirs
    the same way)."""
    order = json.loads((SHADERS / "looks" / "looks.json").read_text())["files"]
    return "\n".join([(SHADERS / "theme.frag").read_text()]
                     + [(SHADERS / "looks" / f"{n}.glsl").read_text() for n in order])


SHADER = shader_source()
THEMES = REPO / "system_files" / "usr" / "share" / "pulsar" / "themes"
PREVIEW = REPO / ".preview"
LOOKS = {n: float(i) for i, n in enumerate(json.loads((SHADERS / "looks" / "looks.json").read_text())["looks"])}
PREAMBLE = "#version 330 core\nout vec4 _o;\n#define gl_FragColor _o\n"
VERTEX = "#version 330 core\nin vec2 in_pos;\nvoid main(){gl_Position=vec4(in_pos,0.0,1.0);}\n"

DEFAULTS = dict(desat=0.18, gain=1.0, stars=1.0, down=0.17, wash=0.35, fold=2.2,
                seed=[0.0, 0.0], dir=[-0.8, -0.6], bloom=[0.42, -0.06], beam=-0.35, time=0.0, quiet=1.0, glow=1.0, signal=1.0, grain=1.0, web=None)


def color(v, spec):
    """'blue', '#aabbcc', or 'a~b@t' (t of the way from a to b, in OKLab)."""
    spec = spec.strip()
    if "~" in spec:
        a, rest = spec.split("~", 1)
        b, t = rest.rsplit("@", 1)
        ca, cb, t = color(v, a), color(v, b), float(t)
        la, lb = ca.oklab(), cb.oklab()
        return pt.from_oklab(*(x + (y - x) * t for x, y in zip(la, lb)))
    if spec.startswith("#"):
        return pt.Color.parse(spec)
    if spec in ("white", "black"):
        return pt.WHITE if spec == "white" else pt.BLACK
    return v[spec]


# A look with no table of its own in a theme (every look the site's hero can
# show, not just the ones the theme ships as wallpapers) is that theme's look
# all the same: the looks drawn since the first four take their colours and
# light direction from the variant's primary table -- the theme's own choice
# of lights -- and their other knobs from the defaults. (Silk, Leak and Holo
# without a table keep the renderer's defaults, as the site has always shown
# them.)
INHERITED = ("c1", "c2", "c3", "c4", "star", "ground_far", "ground_near", "dawn_bottom", "dawn_top",
             "desat", "dir", "wash")
FIRST_FOUR = ("silk", "leak", "holo")


def spec_for(theme, variant, look):
    """The render table for a look, as the pipeline would render it."""
    specs = [sp for sp in theme.raw.get("wallpaper", {}).get("render", []) if sp["variant"] == variant]
    own = next((sp for sp in specs if sp["look"] == look), None)
    if own is not None or look in FIRST_FOUR:
        return own or {"variant": variant, "look": look}
    names = theme.raw.get("wallpaper", {}).get(variant) or []
    first = pathlib.Path(names[0]).stem.split("-")[0] if names else None
    primary = next((sp for sp in specs if sp["look"] == first), specs[0] if specs else {})
    return {"variant": variant, "look": look, **{k: primary[k] for k in INHERITED if k in primary}}


def uniforms(theme, spec):
    v = theme.variants[spec["variant"]]
    s = {**DEFAULTS, **spec}
    if s["web"] is None:
        # Silk carries its filament web well; on the smooth looks (leak, satin,
        # holo) a full-strength web read as electrical crackle. A render can
        # still ask for more -- the phosphor themes do.
        s["web"] = {"silk": 1.0, "satin": 0.45}.get(spec["look"], 0.55)
    if "seed" not in spec:
        # Looks other than silk take the seed only for their filament field and
        # sky; without one, every theme on the same look drew the same trails.
        # Derived from slug + look + variant: distinct, and deterministic.
        h = hashlib.sha256(f"{theme.slug}/{spec['look']}/{spec['variant']}".encode()).digest()
        s["seed"] = [h[0] / 25.5 - 5.0, h[1] / 25.5 - 5.0]
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
    for k in ("desat", "gain", "stars", "down", "wash", "fold", "beam", "quiet", "glow", "signal", "grain", "web"):
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


def write_uniforms(out):
    """The uniforms this renderer hands theme.frag, for the site's live hero.

    The hero runs this same shader, recolored by the site's theme exactly as
    the wallpapers are: for every theme, variant and look (looks.json), the
    uniforms render() would be given -- the theme's own [[wallpaper.render]]
    table for that look where it has one, spec_for()'s where it does not. So any look the visitor picks is
    the look this pipeline would render for that theme. "primary" is the
    variant's first wallpaper, the one the theme sets on the desktop.

    A theme with no render tables (Pulsar, Pulsar Holo) wears assets/shaders/
    pulsar.frag's own brand looks instead; its first wallpaper names the look.
    """
    import json
    data = {}
    for tt in sorted(THEMES.glob("*/theme.toml")):
        theme = pt.Theme(tt)
        walls = theme.raw.get("wallpaper", {})
        specs = walls.get("render", [])
        entry = {"shader": "theme" if specs else "pulsar", "variants": {}}
        for variant in ("dark", "light"):
            names = walls.get(variant) or []
            if not names or variant not in theme.variants:
                continue
            first = pathlib.Path(names[0]).stem
            if specs:
                table = {sp["look"]: sp for sp in specs if sp["variant"] == variant}
                looks = {}
                for look in LOOKS:
                    looks[look] = {k: (list(v) if isinstance(v, tuple) else v)
                                   for k, v in uniforms(theme, spec_for(theme, variant, look)).items()}
                primary = first.split("-")[0]
                if primary not in table:
                    sys.exit(f"{theme.slug}: {variant} wallpaper {names[0]} has no render table")
                entry["variants"][variant] = {"primary": primary, "looks": looks}
            else:
                # /usr/share/backgrounds/pulsar/pulsar-<look>-<variant>.png
                look = first.split("-")[-2]
                if look not in LOOKS:
                    sys.exit(f"{theme.slug}: cannot read a look from {names[0]}")
                entry["variants"][variant] = {"primary": look}
        data[theme.slug] = entry
    out.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
    print(f"uniforms for {len(data)} themes: {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append")
    ap.add_argument("--width", type=int, default=2560)
    ap.add_argument("--height", type=int, default=1600)
    ap.add_argument("--preview", action="store_true", help="640x400 into .preview/themes/, for tuning")
    ap.add_argument("--sheet", action="store_true", help="also write .preview/theme-wallpapers.png")
    ap.add_argument("--sheet-only", action="store_true")
    ap.add_argument("--uniforms", metavar="FILE",
                    help="write every theme's render uniforms as JSON (no GL needed) and exit")
    a = ap.parse_args()
    if a.uniforms:
        return write_uniforms(pathlib.Path(a.uniforms))
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
