#!/usr/bin/env python3
"""Render a brand SVG to half-block ANSI art for `pulsar manifest`.

Hand-drawing the mark in block characters was a bad idea twice over: it came
out as a closed ring when the mark is an open sweep that tapers, and it would
drift from assets/brand/ the moment the art changed. This rasterises the real
SVG instead, so the terminal readout and the wallpaper are the same artwork.

Two pixel rows share one character cell via U+2580 (upper half block): the top
row becomes the foreground colour, the bottom row the background. That gives
square pixels out of a cell that is twice as tall as it is wide, and 24-bit
colour carries the sweep's cyan-to-violet gradient for free.

Transparent pixels emit no background, so the terminal's own colour shows
through and the art sits on whatever theme the user runs.

    render-ascii-logo.py assets/brand/pulsar-mark.svg -o out.ansi [--cols 26]
"""
import argparse
import re
import subprocess
import sys

# A real ASCII ramp: 7-bit characters only, lightest to heaviest. Half-block
# glyphs would carry twice the vertical detail, but they are Unicode, they are
# East Asian Ambiguous width, and a terminal that renders them double-wide
# shears the column beside them. One byte per character also makes the padding
# arithmetic exact instead of locale-dependent.
RAMP = " .:-=+*#%@"


def rasterise(svg, cols):
    """SVG -> {(x, y): (r, g, b, a)}, sampled 2:1 so the art reads square.

    A character cell is about twice as tall as it is wide, so the raster is
    half as many rows as columns; rendering it square would stretch the mark
    into an ellipse.
    """
    rows = cols // 2
    out = subprocess.run(
        ["magick", "-background", "none", svg,
         "-resize", f"{cols}x{rows}!", "-depth", "8", "txt:-"],
        capture_output=True, text=True, check=True).stdout
    px = {}
    for line in out.splitlines():
        if ":" not in line or line.startswith("#"):
            continue
        coord, rest = line.split(":", 1)
        x, y = (int(v) for v in coord.split(","))
        body = rest.split("#")[1].split()[0]
        r, g, b = (int(body[i:i + 2], 16) for i in (0, 2, 4))
        a = int(body[6:8], 16) if len(body) >= 8 else 255
        px[(x, y)] = (r, g, b, a)
    return px


def cell(px):
    """One coloured ASCII character for one pixel.

    Density comes from alpha, colour from the pixel. The sweep tapers to well
    under one pixel at this size, so a cutoff tuned for the thick head erases
    the tail entirely -- which is the part that makes it a sweep and not a
    ring. The ramp keeps those pixels as faint characters instead.
    """
    r, g, b, a = px
    if a <= 8:
        return " "
    # gamma-lifted: the taper spends most of its length at low coverage, and
    # a linear ramp renders all of it as the same faint dot
    idx = min(len(RAMP) - 1, max(1, round((a / 255) ** 0.62 * (len(RAMP) - 1))))
    return f"\033[38;2;{r};{g};{b}m{RAMP[idx]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("svg")
    ap.add_argument("-o", "--out")
    ap.add_argument("--cols", type=int, default=26)
    args = ap.parse_args()

    if args.cols % 2:
        sys.exit("--cols must be even")

    px = rasterise(args.svg, args.cols)
    lines = []
    for row in range(args.cols // 2):
        line = "".join(cell(px.get((x, row), (0, 0, 0, 0))) for x in range(args.cols))
        # NOT rstripped: every line keeps exactly `cols` visible characters,
        # so the column beside it needs no width arithmetic at all
        lines.append(line + "\033[0m")

    # Drop fully blank leading/trailing rows: the SVG has generous padding for
    # the glow, and in a terminal that padding is just the readout pushed down.
    def blank(ln):
        return not re.sub(r"\033\[[0-9;]*m", "", ln).strip()

    while lines and blank(lines[0]):
        lines.pop(0)
    while lines and blank(lines[-1]):
        lines.pop()

    text = "\n".join(lines) + "\n"
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        print(f"{args.out}: {len(lines)} rows x {args.cols} columns", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
