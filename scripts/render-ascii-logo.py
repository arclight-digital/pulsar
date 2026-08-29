#!/usr/bin/env python3
"""Render a brand SVG to colored-ASCII art for `pulsar manifest`.

Hand-drawing the mark was a bad idea twice over: it came out as a closed ring
when the mark is an open sweep that tapers, and it would drift from
assets/brand/ the moment the art changed. This rasterises the real SVG
instead, so the terminal readout and the wallpaper are the same artwork.

Each pixel becomes one 7-bit character from a density ramp, with the pixel's
own color as 24-bit foreground -- so the sweep keeps its cyan-to-violet
gradient. Transparent pixels are plain spaces, so the art sits on whatever
theme the user's terminal runs.

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

    # Kept as a grid of CELLS rather than joined strings until the trimming is
    # done. A cell is one coloured character, so a cell is blank iff it is
    # exactly " " -- which makes "is this column empty" a question that can be
    # asked at all. On joined lines it cannot: the escapes make column N of the
    # string and column N of the art different things.
    px = rasterise(args.svg, args.cols)
    grid = [[cell(px.get((x, row), (0, 0, 0, 0))) for x in range(args.cols)]
            for row in range(args.cols // 2)]

    # Drop fully blank rows AND fully blank columns. The SVG has generous
    # padding for the glow, and in a terminal that padding is dead space in
    # both directions: above and below it is the readout pushed down, left and
    # right it is a margin the mark does not use and a gap between the art and
    # the values that reads as a layout mistake.
    #
    # Columns matter more than rows here. The art is padded to a fixed width
    # and the readout is pasted at that offset, so every blank column on the
    # right is a column of gap nobody chose, and every blank column on the
    # left is indent. Trimming them also makes the art genuinely narrower,
    # which is what decides whether it is drawn at all on a small terminal.
    blank_row = lambda r: all(c == " " for c in r)
    while grid and blank_row(grid[0]):
        grid.pop(0)
    while grid and blank_row(grid[-1]):
        grid.pop()

    used = [x for x in range(args.cols) if any(row[x] != " " for row in grid)]
    if used:
        # One slice for every row, so the lines stay exactly as wide as each
        # other -- the invariant the paste depends on survives the trim.
        lo, hi = used[0], used[-1] + 1
        grid = [row[lo:hi] for row in grid]

    # NOT rstripped: every line keeps the same number of visible characters,
    # so the column beside it needs no width arithmetic at all.
    lines = ["".join(row) + "\033[0m" for row in grid]

    text = "\n".join(lines) + "\n"
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text)
        width = len(grid[0]) if grid else 0
        print(f"{args.out}: {len(lines)} rows x {width} columns "
              f"(from --cols {args.cols})", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
