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

# All eight shipped wallpapers: four looks x two themes. u_theme switches the
# palette and mood (0 = night, 1 = dawn); u_look picks the composition
# (0 silk / 1 leak / 2 satin / 3 holo). Silk is the default pair -- the
# gschema override and the lock screen point at it by name -- and all four
# pairs are listed in gnome-background-properties/pulsar.xml, so KEEP THE
# FILENAMES IN SYNC with both of those if anything here changes.
#
# The mark is pasted after the render -- it is alpha art with a gaussian glow,
# and reimplementing that in GLSL to avoid one PIL call would be absurd. Dark
# cuts carry the full-color mark; light cuts derive an INK mark from the
# authored mono art (flat #241F3D over its alpha) -- the standalone ink
# rasters were retired with the generated lockups, and this matches
# sync-branding.sh's ink() treatment exactly.
ICONS = REPO / "assets" / "icons"
INK = (36, 31, 61, 255)  # #241F3D
LOOKS = {"silk": 0.0, "leak": 1.0, "satin": 2.0, "holo": 3.0}
VARIANTS = [
    (f"pulsar-{name}-{theme}.png",
     dict(u_time=0.0, u_theme=t, u_look=look),
     ICONS / mark, inked)
    for name, look in LOOKS.items()
    for theme, t, mark, inked in [("dark", 0.0, "pulsar-mark-1024.png", False),
                                  ("light", 1.0, "pulsar-mark-mono-1024.png", True)]
]

LOGO_FRAC = 0.30   # mark height as a fraction of screen height
LOGO_LIFT = 0.02   # optical center: nudge above true center by this much of H


def render(width, height, uniforms):
    import moderngl
    import numpy as np

    ctx = moderngl.create_standalone_context(backend="egl")
    prog = ctx.program(
        vertex_shader=VERTEX,
        fragment_shader=PREAMBLE + SHADER.read_text(),
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


def composite_logo(img, logo, inked=False):
    from PIL import Image

    size = round(img.height * LOGO_FRAC)
    mark = Image.open(logo).convert("RGBA")
    if inked:
        solid = Image.new("RGBA", mark.size, INK)
        solid.putalpha(mark.getchannel("A"))
        mark = solid
    mark = mark.resize((size, size), Image.LANCZOS)
    x = (img.width - size) // 2
    y = (img.height - size) // 2 - round(img.height * LOGO_LIFT)
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

    for name, uniforms, logo, inked in VARIANTS:
        img = composite_logo(render(args.width, args.height, uniforms), logo, inked)
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
