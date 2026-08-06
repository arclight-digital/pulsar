#!/usr/bin/env python3
"""Render the og.jpg share card: mark + wordmark + tagline over silk.

The background is the same silk-dark field the wallpapers use, rendered by
the same shader at card size; the type is set from the shipped Host Grotesk
cuts. Regenerate whenever the tagline changes -- the card is pixels, and
pixels do not update themselves:

    ./scripts/shader-preview.sh --rebuild   # if the render image is stale
    podman run --rm -v "$PWD:/repo:z" --entrypoint python3 \
      localhost/pulsar-shader /repo/scripts/render-og.py

Writes site/assets-static/og.jpg (1200x630, the Open Graph standard size).
"""
import os
import pathlib

os.environ.setdefault("PYOPENGL_PLATFORM", "egl")

REPO = pathlib.Path(__file__).resolve().parent.parent
SHADER = REPO / "assets" / "shaders" / "pulsar.frag"
MARK = REPO / "assets" / "brand" / "pulsar-mark-1024.png"
FONTS = REPO / "assets" / "fonts" / "Host_Grotesk" / "static"
OUT = REPO / "site" / "assets-static" / "og.jpg"

W, H = 1200, 630
TAGLINE = "Your lighthouse in the sky."

PREAMBLE = """#version 330 core
out vec4 _pulsar_fragColor;
#define gl_FragColor _pulsar_fragColor
"""
VERTEX = """#version 330 core
in vec2 in_pos;
void main() { gl_Position = vec4(in_pos, 0.0, 1.0); }
"""


def render_background():
    import moderngl
    import numpy as np

    ctx = moderngl.create_standalone_context(backend="egl")
    prog = ctx.program(vertex_shader=VERTEX,
                       fragment_shader=PREAMBLE + SHADER.read_text())
    verts = np.array([-1, -1, 3, -1, -1, 3], dtype="f4")
    vao = ctx.simple_vertex_array(prog, ctx.buffer(verts), "in_pos")
    for name, value in {"u_resolution": (float(W), float(H)),
                        "u_time": 0.0, "u_theme": 0.0, "u_look": 0.0}.items():
        if name in prog:
            prog[name].value = value
    fbo = ctx.simple_framebuffer((W, H), components=3)
    fbo.use()
    fbo.clear(0.0, 0.0, 0.0)
    vao.render(moderngl.TRIANGLES)

    from PIL import Image
    img = Image.frombytes("RGB", (W, H), fbo.read(components=3))
    return img.transpose(Image.FLIP_TOP_BOTTOM)


def tracked_text(draw, xy_center, text, font, tracking, fill):
    """Letter-spaced text centered on x -- PIL has no tracking of its own."""
    widths = [draw.textlength(c, font=font) for c in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = xy_center[0] - total / 2
    for c, w in zip(text, widths):
        draw.text((x, xy_center[1]), c, font=font, fill=fill)
        x += w + tracking


def main():
    from PIL import Image, ImageDraw, ImageFont

    img = render_background().convert("RGBA")

    mark = Image.open(MARK).convert("RGBA").resize((210, 210), Image.LANCZOS)
    img.paste(mark, ((W - 210) // 2, 88), mark)

    draw = ImageDraw.Draw(img)
    wordmark = ImageFont.truetype(str(FONTS / "HostGrotesk-Medium.ttf"), 58)
    tagline = ImageFont.truetype(str(FONTS / "HostGrotesk-Regular.ttf"), 31)
    tracked_text(draw, (W / 2, 370), "PULSAR", wordmark,
                 tracking=34, fill=(233, 237, 247, 255))
    tw = draw.textlength(TAGLINE, font=tagline)
    draw.text(((W - tw) / 2, 462), TAGLINE, font=tagline,
              fill=(201, 208, 228, 255))

    img.convert("RGB").save(OUT, quality=84, optimize=True, progressive=True)
    print(f"{OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
