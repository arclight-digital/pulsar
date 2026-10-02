#!/usr/bin/python3
"""The glass blur's kernel, simulated: glass.js's Kawase pyramid (five-tap down,
eight-tap tent up, bilinear taps) run on one bright point. Prints its width
(sigma, in half-size texels) and how uneven it is around a circle of that
radius: a diamond shows as a high number. Needs numpy (a toolbox has it).
    blur_kernel.py LEVELS OFFSET [SCALE ...]
"""
import numpy as np
def bil(img, ys, xs):
    H, W = img.shape
    ys = np.clip(ys, 0, H - 1); xs = np.clip(xs, 0, W - 1)
    y0 = np.floor(ys).astype(int); x0 = np.floor(xs).astype(int)
    y1 = np.minimum(y0 + 1, H - 1); x1 = np.minimum(x0 + 1, W - 1)
    fy = ys - y0; fx = xs - x0
    return (img[y0, x0] * (1 - fy) * (1 - fx) + img[y0, x1] * (1 - fy) * fx +
            img[y1, x0] * fy * (1 - fx) + img[y1, x1] * fy * fx)
def down(src, h):
    H, W = src.shape; h2, w2 = H // 2, W // 2
    yy, xx = np.mgrid[0:h2, 0:w2].astype(float)
    cy, cx = (yy + 0.5) * 2 - 0.5, (xx + 0.5) * 2 - 0.5     # texel centres in src
    c = bil(src, cy, cx) * 4
    for dy, dx in ((-h, -h), (h, h), (-h, h), (h, -h)):
        c += bil(src, cy + dy, cx + dx)
    return c / 8
def up(src, shape, h):
    H, W = shape; sh, sw = src.shape
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    cy, cx = (yy + 0.5) * sh / H - 0.5, (xx + 0.5) * sw / W - 0.5
    taps = [((0, -2 * h), 1), ((h, -h), 2), ((2 * h, 0), 1), ((h, h), 2), ((0, 2 * h), 1), ((-h, h), 2), ((-2 * h, 0), 1), ((-h, -h), 2)]
    c = sum(bil(src, cy + dy, cx + dx) * w for (dy, dx), w in taps)
    return c / 12
def psf(levels, offset, scale=1.0, N=512):
    extra = max(0, round(np.log2(scale))) ; n = levels + extra; off = offset * scale / 2 ** extra
    img = np.zeros((N, N)); img[N // 2, N // 2] = 1.0
    pyr = [img]
    for i in range(n):
        pyr.append(down(pyr[-1], 0.5 * off))
    cur = pyr[-1]
    for i in range(n - 1, -1, -1):
        cur = up(cur, pyr[i].shape, 0.5 * off)
    return cur / cur.sum()
def measure(p):
    N = p.shape[0]; c = N // 2
    yy, xx = np.mgrid[0:N, 0:N] - c
    r = np.hypot(yy, xx); sigma = np.sqrt((p * r ** 2).sum() / 2)
    # roundness: at radius = sigma, sample 360 angles; spread of values / mean
    ang = np.linspace(0, 2 * np.pi, 360, endpoint=False)
    rad = sigma
    vals = bil(p, c + rad * np.sin(ang), c + rad * np.cos(ang))
    aniso = (vals.max() - vals.min()) / vals.mean()
    # ghosting: count local maxima on a ring band (a smooth blur has one, at centre)
    return sigma, aniso


if __name__ == "__main__":
    import sys
    levels, offset = int(sys.argv[1]), float(sys.argv[2])
    for sc in [float(v) for v in sys.argv[3:]] or [1.0, 1.333, 2.0]:
        s, a = measure(psf(levels, offset, sc))
        print(f"levels {levels} offset {offset} @{sc}x: width {s:5.2f}  unevenness {a * 100:5.1f}%")
