#!/usr/bin/env python3
"""Render assets/shaders/pulsar.frag to the wallpapers the image ships.

Headless, via EGL + llvmpipe, so it runs on a CI runner with no GPU. The
shader is the source of truth; this only supplies uniforms and writes PNGs.

Not run during the container build -- there is no GL stack in the build
container, and adding one to ship two PNGs would be absurd. CI renders first,
then `podman build` picks the results up out of system_files/.

  python3 scripts/render-wallpapers.py [--out DIR] [--width W] [--height H]
"""
import argparse
import os
import pathlib
import sys

# EGL, not GLX: there is no X display on a runner. Must be set before the GL
# context is created, which moderngl does at import-and-create time.
os.environ.setdefault("PYOPENGL_PLATFORM", "egl")

REPO = pathlib.Path(__file__).resolve().parent.parent
SHADER = REPO / "assets" / "shaders" / "pulsar.frag"
LOOKS_DIR = REPO / "assets" / "shaders" / "looks"


def shader_source():
    """pulsar.frag, then every look file in looks/looks.json's order -- the
    shader as it compiles. theme.frag, the renderer of the theme wallpapers
    and the site's live sky assemble theirs the same way."""
    import json
    order = json.loads((LOOKS_DIR / "looks.json").read_text())["files"]
    return "\n".join([SHADER.read_text()] + [(LOOKS_DIR / f"{n}.glsl").read_text() for n in order])

# The shader is written glslViewer-style (gl_FragColor, no #version). Alias it
# forward rather than rewriting the shader, so the same file stays usable with
# `glslViewer assets/shaders/pulsar.frag` for interactive tuning.
PREAMBLE = """#version 330 core
out vec4 _pulsar_fragColor;
#define gl_FragColor _pulsar_fragColor
"""

VERTEX = """#version 330 core
in vec2 in_pos;
void main() { gl_Position = vec4(in_pos, 0.0, 1.0); }
"""

# Every shipped brand wallpaper: each look (looks/looks.json) x two themes.
# u_theme switches the palette and mood (0 = night, 1 = dawn); u_look picks
# the look. Silk is the default pair -- the gschema override and the lock
# screen point at it by name -- and every pair is listed in
# gnome-background-properties/pulsar.xml and themes/pulsar/theme.toml, so KEEP
# THE FILENAMES IN SYNC with those if anything here changes.
#
# The mark is pasted after the render -- it is alpha art with a gaussian glow,
# and reimplementing that in GLSL to avoid one PIL call would be absurd. Dark
# cuts carry the colour-on-dark mark; light cuts carry the authored -light
# mark (soft cyan -> violet sweep, deep-violet core -- the light-ground cut,
# not a recolour).
#
# Each PNG is paired with the SVG it was exported from, because the PNG alone
# does not say where the mark sits in it. The v2 files are cropped to their own
# art plus 3%, so the dark mark (which carries a glow) and the light one (which
# does not) have different boxes, and neither is centred on the core. Pasting
# the boxes at one size would draw the light mark 15% larger than the dark one
# and put both cores off the optical centre -- the pair would visibly jump when
# GNOME flips between them. The SVG's viewBox gives the box in the mark's own
# 256-unit drawing grid, where the core is always at (128, 128), so the paste
# scales and places by the drawing instead of by the box.
BRAND = REPO / "assets" / "brand"
def _looks():
    import json
    names = json.loads((REPO / "assets" / "shaders" / "looks" / "looks.json").read_text())["looks"]
    return {n: float(i) for i, n in enumerate(names)}


LOOKS = _looks()     # u_look for each look, in looks/looks.json's order
MARKS = {"dark": ("png/pulsar-mark-1024.png", "svg/pulsar-mark.svg"),
         "light": ("png/pulsar-mark-light-1024.png", "svg/pulsar-mark-light.svg")}
VARIANTS = [
    (f"pulsar-{name}-{theme}.png",
     dict(u_time=0.0, u_theme=t, u_look=look),
     MARKS[theme])
    for name, look in LOOKS.items()
    for theme, t in [("dark", 0.0), ("light", 1.0)]
]

GRID = 256.0         # the mark's drawing grid, in SVG user units
CORE = (128.0, 128.0)  # the core's centre in that grid, in every v2 mark file
LOGO_FRAC = 0.30   # the 256-unit grid's height as a fraction of screen height
LOGO_LIFT = 0.02   # optical center: nudge above true center by this much of H


def render(width, height, uniforms):
    import moderngl
    import numpy as np

    ctx = moderngl.create_standalone_context(backend="egl")
    prog = ctx.program(
        vertex_shader=VERTEX,
        fragment_shader=PREAMBLE + shader_source(),
    )
    # Fullscreen triangle beats a quad: one primitive, no diagonal seam.
    verts = np.array([-1, -1, 3, -1, -1, 3], dtype="f4")
    vao = ctx.simple_vertex_array(prog, ctx.buffer(verts), "in_pos")

    for name, value in {"u_resolution": (float(width), float(height)), **uniforms}.items():
        if name in prog:
            prog[name].value = value

    fbo = ctx.simple_framebuffer((width, height), components=3)
    fbo.use()
    fbo.clear(0.0, 0.0, 0.0)
    vao.render(moderngl.TRIANGLES)

    from PIL import Image

    img = Image.frombytes("RGB", (width, height), fbo.read(components=3))
    # GL's origin is bottom-left; PNG's is top-left.
    return img.transpose(Image.FLIP_TOP_BOTTOM)


def viewbox(svg):
    """(x, y, w, h) of an SVG's viewBox -- where its PNG export sits in the grid."""
    import re

    head = svg.read_text(errors="replace")[:4096]
    m = re.search(r'viewBox="([^"]+)"', head)
    if not m:
        sys.exit(f"render-wallpapers: no viewBox in {svg}")
    return tuple(float(v) for v in m.group(1).replace(",", " ").split())


def composite_logo(img, logo):
    from PIL import Image

    png, svg = (BRAND / f for f in logo)
    vx, vy, vw, vh = viewbox(svg)
    unit = img.height * LOGO_FRAC / GRID          # screen px per grid unit
    w, h = round(vw * unit), round(vh * unit)
    mark = Image.open(png).convert("RGBA").resize((w, h), Image.LANCZOS)
    # Put the CORE on the optical centre, not the box: the box is off-core by
    # a different amount in every file.
    x = round(img.width / 2 - (CORE[0] - vx) * unit)
    y = round(img.height / 2 - img.height * LOGO_LIFT - (CORE[1] - vy) * unit)
    img.paste(mark, (x, y), mark)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO / "system_files/usr/share/backgrounds/pulsar"))
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--height", type=int, default=2160)
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for name, uniforms, logo in VARIANTS:
        img = composite_logo(render(args.width, args.height, uniforms), logo)
        img.save(out / name, optimize=True)
        print(f"  {out / name} ({args.width}x{args.height})")

    # default.png predates the four-pair layout; the gschema override now
    # names pulsar-silk-*.png directly. Clean up a stale symlink if present.
    default = out / "default.png"
    if default.exists() or default.is_symlink():
        default.unlink()
        print(f"  removed stale {default}")


if __name__ == "__main__":
    sys.exit(main())
