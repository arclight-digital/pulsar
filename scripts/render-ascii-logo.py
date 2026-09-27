#!/usr/bin/env python3
"""Render a brand SVG to colored-ASCII art for `pulsar manifest`.

Hand-drawing the mark was a bad idea twice over: it came out as a closed ring
when the mark is an open sweep that tapers, and it would drift from
assets/brand/ the moment the art changed. This rasterises the real SVG
instead, so the terminal readout and the wallpaper are the same artwork.

Three things decide how faithful the result is:

  * Cell shape. A terminal cell is not square and not exactly 2:1 either;
    it is the font's advance by its ascent plus descent. JetBrains Mono, the
    image's terminal font, is 0.6em by 1.32em -- 2.2:1. The cell is measured
    from the font rather than assumed, and the art is fitted into cells of
    that shape, so the mark comes out round instead of as an ellipse.

  * Shape, not just density. Every printable ASCII character is drawn in that
    font and reduced to a small grid of ink coverage (ZONES_X by ZONES_Y).
    Each cell of the artwork is reduced the same way, and gets the character
    whose ink falls in the same places. An edge running through a cell picks
    `/`, `(`, `_` or `'` by where the edge is, where a density ramp could
    only say "about half full" and draw the same dot everywhere.

  * Colour. Each character takes the average colour of the ink in its cell,
    weighted by coverage, rather than whichever pixel sat at its centre.

The soft glow (the halo, the bloom, any blurred group) is rendered as its
own layer: light characters in the glow's colour with the faint attribute
(SGR 2), in cells the mark itself leaves empty. Faint is dimmed against the
terminal's own background, so the glow stays quieter than the mark on dark
and light themes alike -- a darker colour would do that only on dark ones.
Empty cells are plain spaces, so the art sits on whatever theme the
terminal runs.

    render-ascii-logo.py assets/brand/svg/pulsar-mark-small.svg -o out.ansi [--rows 19]
        [--no-glow] [--preview out.png]
"""
import argparse
import io
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw, ImageFont

# 7-bit printable ASCII only. Half-block glyphs would carry twice the vertical
# detail, but they are Unicode, they are East Asian Ambiguous width, and a
# terminal that renders them double-wide shears the column beside them. One
# byte per character also makes the padding arithmetic exact instead of
# locale-dependent.
#
# And not all of it. Letters and digits match shapes well in isolation, but
# at this size a stray `J`, `7` or `$` on the rim reads as text, and mixing
# fills (`#`, `%`, `0` beside `@`) reads as noise where the drawing is one
# flat colour. What is left is the set an ASCII artist reaches for: marks
# for a sliver of ink at each edge and corner, strokes for each direction,
# `g` for ink that sits low in the cell, and `@` for the body.
CHARSET = " .,'`\"-_^:;/\\|()<>@g"

# The glow is a gradient with no edges, so it takes a plain density ramp,
# dithered between steps: where a hard threshold would cut the halo off in a
# ring of dots, the dots thin out and fade instead. The dither is a fixed
# hash of the cell rather than a Bayer matrix, whose grid reads as a
# checkerboard at this size; the hash scatters like starlight, and is the
# same on every run so the shipped file only changes when the art does.
GLOW_RAMP = ".:"


def scatter(r, c):
    """A fixed pseudo-random threshold in [0, 1) for cell (r, c)."""
    h = (r * 374761393 + c * 668265263) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65536

FONT = "/usr/share/fonts/pulsar/jetbrains-mono/JetBrainsMono-Regular.ttf"

# Ink is compared on a 4x9 grid per cell: at 2.2:1 that makes each zone
# roughly square, so a stroke counts the same whichever way it runs, and fine
# enough to tell `(` from `<` and `_` from `.`.
ZONES_X, ZONES_Y = 4, 9

SVG_NS = "http://www.w3.org/2000/svg"
GLOW_CLASSES = {"pl-halo", "pl-bloom"}


def font_path(requested):
    if requested:
        return requested
    try:
        return subprocess.run(["fc-match", "-f", "%{file}", "JetBrains Mono"],
                              capture_output=True, text=True, check=True).stdout or FONT
    except (OSError, subprocess.CalledProcessError):
        return FONT


def split_glow(svg_text):
    """(ink, glow): the SVG with only the mark, and with only its glow.

    Glow is the halo, the bloom and any blurred group. Both halves keep the
    same viewBox, so they rasterise onto the same pixels.
    """
    for prefix, uri in re.findall(r'xmlns:?(\w*)="([^"]+)"', svg_text):
        ET.register_namespace(prefix, uri)

    def glow(el):
        return bool(GLOW_CLASSES & set(el.get("class", "").split())) or "filter" in el.attrib

    def keep(want_glow):
        root = ET.fromstring(svg_text)
        for child in list(root):
            tag = child.tag.rsplit("}", 1)[-1]
            if tag in ("defs", "metadata"):
                continue
            if glow(child) != want_glow:
                root.remove(child)
        if not want_glow:
            for parent in list(root.iter()):
                for child in list(parent):
                    if glow(child):
                        parent.remove(child)
        return ET.tostring(root, encoding="unicode")

    return keep(False), keep(True)


def rasterise(svg_text, height):
    """SVG -> RGBA image `height` pixels tall."""
    png = subprocess.run(
        ["magick", "-background", "none", "-density", "600", "svg:-",
         "-resize", f"x{height}", "png:-"],
        input=svg_text.encode(), capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def fit(img, box, cols, rows, cw, ch, scale):
    """Crop to `box`, scale, and centre on a canvas of cols x rows cells."""
    img = img.crop(box)
    img = img.resize((max(1, round(img.width * scale)), rows * ch), Image.LANCZOS)
    canvas = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
    canvas.alpha_composite(img, ((cols * cw - img.width) // 2, 0))
    return canvas


def glyph_vectors(font, cw, ch, charset):
    """{char: zone coverage}, each zone scaled by the heaviest glyph there.

    Scaling per zone is what lets a fully inked cell find a glyph at all: no
    character covers its whole cell, so raw coverage would never match 1.0.
    """
    raw = {}
    for c in " " + charset.replace(" ", ""):
        im = Image.new("L", (cw, ch), 0)
        ImageDraw.Draw(im).text((0, 0), c, font=font, fill=255)  # top = ascent line, as a terminal draws it
        small = im.resize((ZONES_X, ZONES_Y), Image.BOX)
        raw[c] = [small.getpixel((i, j)) / 255 for j in range(ZONES_Y) for i in range(ZONES_X)]
    peak = [max(v[i] for v in raw.values()) or 1 for i in range(ZONES_X * ZONES_Y)]
    return {c: [x / p for x, p in zip(v, peak)] for c, v in raw.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("svg")
    ap.add_argument("-o", "--out")
    ap.add_argument("--rows", type=int, default=19, help="height of the art in lines")
    ap.add_argument("--font", help="TTF to measure cells and draw glyphs with (default: JetBrains Mono)")
    ap.add_argument("--cell-aspect", type=float, help="cell height / width, overriding the font's")
    ap.add_argument("--contrast", type=float, default=1.6,
                    help="sharpen each cell's ink towards its strongest zone (1 = off)")
    ap.add_argument("--threshold", type=float, default=0.10,
                    help="cells whose strongest zone is under this coverage stay blank")
    ap.add_argument("--glow", type=float, default=0.9,
                    help="glow density, 1 = the glow's brightest cell gets the heaviest glow character")
    ap.add_argument("--charset", default=CHARSET, help="characters the mark may be drawn with")
    ap.add_argument("--no-glow", action="store_true", help="leave the halo and bloom out")
    ap.add_argument("--preview", help="also draw the result to this PNG, as a terminal would")
    args = ap.parse_args()

    font = ImageFont.truetype(font_path(args.font), 50)
    ascent, descent = font.getmetrics()
    cw = round(font.getlength("M"))
    aspect = args.cell_aspect or (ascent + descent) / cw
    ch = round(cw * aspect)

    with open(args.svg) as fh:
        ink_svg, glow_svg = split_glow(fh.read())

    # Fit the ink to the rows asked for, keeping its true proportions: the
    # width in cells follows from the art's own aspect and the cell's. The
    # glow is cropped to the same box -- the mark decides the frame, and glow
    # beyond it would only be margin.
    ink = rasterise(ink_svg, args.rows * ch * 2)
    box = ink.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox() or (0, 0, ink.width, ink.height)
    bw, bh = box[2] - box[0], box[3] - box[1]
    scale = args.rows * ch / bh
    cols = max(1, round(bw * scale / cw))
    canvas = fit(ink, box, cols, args.rows, cw, ch, scale)
    glow = None
    if not args.no_glow:
        glow = fit(rasterise(glow_svg, args.rows * ch * 2), box, cols, args.rows, cw, ch, scale)
        glow_px = glow.resize((cols, args.rows), Image.BOX)

    # Pillow premultiplies alpha when it resizes RGBA, so a BOX reduction is
    # exactly the coverage-weighted mean colour of each cell.
    colour = canvas.resize((cols, args.rows), Image.BOX)
    zones = canvas.getchannel("A").resize((cols * ZONES_X, args.rows * ZONES_Y), Image.BOX)
    glyphs = glyph_vectors(font, cw, ch, args.charset)
    blank = glyphs.pop(" ")

    grid = []
    for row in range(args.rows):
        line = []
        for col in range(cols):
            v = [zones.getpixel((col * ZONES_X + i, row * ZONES_Y + j)) / 255
                 for j in range(ZONES_Y) for i in range(ZONES_X)]
            m = max(v)
            if m < args.threshold:
                line.append(None)
                continue
            v = [(x / m) ** args.contrast * m for x in v]
            best = min(glyphs, key=lambda c: sum((a - b) ** 2 for a, b in zip(v, glyphs[c])))
            if sum((a - b) ** 2 for a, b in zip(v, blank)) <= sum((a - b) ** 2 for a, b in zip(v, glyphs[best])):
                line.append(None)
                continue
            line.append((best, colour.getpixel((col, row))[:3], False))
        grid.append(line)

    # Specks: a light mark with no ink around it is anti-aliasing on the rim,
    # not a feature of the drawing. Heavy glyphs stay even alone; a lone `@`
    # is a real blob of ink.
    light = set(" .,'`\"-_~^:;")
    specks = [(r, c) for r in range(args.rows) for c in range(cols)
              if grid[r][c] and grid[r][c][0] in light and not any(
                  grid[r + dr][c + dc]
                  for dr in (-1, 0, 1) for dc in (-1, 0, 1)
                  if (dr or dc) and 0 <= r + dr < args.rows and 0 <= c + dc < cols)]
    for r, c in specks:
        grid[r][c] = None

    # The glow fills only cells the mark left empty, faint, from a ramp. Its
    # strength is measured against its brightest VISIBLE cell: the SVG draws
    # it at a third opacity or less, so on an absolute scale it would hardly
    # register, and its true peak is under the core where it never shows.
    if glow is not None:
        peak = max((glow_px.getpixel((c, r))[3] for r in range(args.rows) for c in range(cols)
                    if grid[r][c] is None), default=255) / 255 or 1
        steps = len(GLOW_RAMP)
        for r in range(args.rows):
            for c in range(cols):
                if grid[r][c] is not None:
                    continue
                *rgb, a = glow_px.getpixel((c, r))
                if a < 6:
                    continue    # nearly clear: its averaged colour is noise
                # steeper than linear: the halo's outer reach thins out, so the
                # mark keeps its silhouette and the glow sits close to it
                v = min(1.0, a / 255 / peak * args.glow) ** 1.4 * steps
                level = int(v) + (v - int(v) > scatter(r, c))
                if level:
                    grid[r][c] = (GLOW_RAMP[min(level, steps) - 1], tuple(rgb), True)

    # Drop fully blank rows and columns. The canvas is fitted to the ink, but
    # the threshold can still leave an edge row or column with nothing drawn;
    # every blank column is a gap between the art and the readout nobody
    # chose, and every blank row pushes the readout down.
    blank_row = lambda r: all(c is None for c in r)
    while grid and blank_row(grid[0]):
        grid.pop(0)
    while grid and blank_row(grid[-1]):
        grid.pop()
    used = [x for x in range(cols) if any(r[x] is not None for r in grid)]
    if used:
        # One slice for every row, so the lines stay exactly as wide as each
        # other -- the invariant the paste depends on survives the trim.
        lo, hi = used[0], used[-1] + 1
        grid = [r[lo:hi] for r in grid]

    # NOT rstripped: every line keeps the same number of visible characters,
    # so the column beside it needs no width arithmetic at all. A style is
    # only emitted when it changes, which keeps the file a third the size.
    lines = []
    for r in grid:
        out, last = [], None
        for c in r:
            if c is None:
                out.append(" ")
                continue
            char, rgb, faint = c
            if (rgb, faint) != last:
                out.append("\033[0;%s38;2;%d;%d;%dm" % (("2;" if faint else ""), *rgb))
                last = (rgb, faint)
            out.append(char)
        lines.append("".join(out) + "\033[0m")
    text = "\n".join(lines) + "\n"

    width = len(grid[0]) if grid else 0
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        print(f"{args.out}: {len(lines)} rows x {width} columns "
              f"(cell {cw}x{ch}, {aspect:.2f}:1)", file=sys.stderr)
    else:
        sys.stdout.write(text)

    if args.preview:
        pad = cw
        im = Image.new("RGB", (width * cw + 2 * pad, len(grid) * ch + 2 * pad), (11, 14, 26))
        d = ImageDraw.Draw(im)
        for y, r in enumerate(grid):
            for x, c in enumerate(r):
                if c:
                    # faint, as VTE draws it: halfway to the background
                    rgb = tuple((v + b) // 2 for v, b in zip(c[1], (11, 14, 26))) if c[2] else c[1]
                    d.text((pad + x * cw, pad + y * ch), c[0], font=font, fill=rgb)
        im.save(args.preview)


if __name__ == "__main__":
    main()
