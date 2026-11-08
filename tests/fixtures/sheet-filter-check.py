#!/usr/bin/python3
"""The in-window sheets' glass filters (tests/theme.bats): sheet-filter-check.py <svg> <gtk.css>

- every feComponentTransfer fits GTK's GPU limit, 32 table entries across
  its channels, or GTK drops the whole filter ("tables too big");
- each filter first lays the page over the window's color, so the glass is
  opaque where the page is clear;
- each ramp (the transfer whose result is "glass") is the surface's own
  color at its middle point, and runs dark to light.
Prints what is wrong and exits 1.
"""
import re
import sys
import xml.etree.ElementTree as ET

NS = "{http://www.w3.org/2000/svg}"
svg, css = sys.argv[1], open(sys.argv[2]).read()
bad = []


def hexrgb(h):
    return [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]


def surface(scheme, k):
    # the scheme's own block of variables (light first, then dark)
    m = re.search(r"@media \(prefers-color-scheme: %s\) \{(.*?)\n\}" % scheme, css, re.S)
    block = m.group(1) if m else css
    v = re.search(r"--%s-bg-color: (?:alpha\()?(#[0-9a-f]{6})" % k, block)
    return hexrgb(v.group(1)) if v else None


filters = ET.parse(svg).getroot().findall(f"{NS}filter")
if len(filters) < 2:
    bad.append(f"only {len(filters)} filters")
for f in filters:
    fid = f.get("id")
    prims = list(f)
    if [p.tag for p in prims[:2]] != [f"{NS}feFlood", f"{NS}feComposite"] or prims[1].get("operator") != "over":
        bad.append(f"{fid}: does not start by laying the page over the window's color")
    for ct in f.iter(f"{NS}feComponentTransfer"):
        n = sum(len(fn.get("tableValues", "").split()) for fn in ct if fn.get("type") == "table")
        if n > 32:
            bad.append(f"{fid}: {ct.get('result')}: {n} table entries, GTK takes 32")
    ramp = next((ct for ct in f.iter(f"{NS}feComponentTransfer") if ct.get("result") == "glass"), None)
    if ramp is None:
        bad.append(f"{fid}: no ramp")
        continue
    chans = [[float(x) for x in ramp.find(f"{NS}feFunc{c}").get("tableValues").split()] for c in "RGB"]
    scheme, k = fid.split("-")
    want = surface(scheme, k)
    mid = [c[len(c) // 2] for c in chans]
    if want is None or any(abs(a - b) > 1.5 / 255 for a, b in zip(mid, want)):
        bad.append(f"{fid}: ramp middle {mid} is not the {k} color {want}")
    luma = lambda i: 0.2126 * chans[0][i] + 0.7152 * chans[1][i] + 0.0722 * chans[2][i]
    if not luma(0) < luma(len(chans[0]) // 2) <= luma(-1) + 1e-9:
        bad.append(f"{fid}: ramp does not run dark to light")
print("\n".join(bad) or "ok")
sys.exit(1 if bad else 0)
