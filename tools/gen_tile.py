#!/usr/bin/env python3
"""Draw the catalog tile (docs/tile.svg, docs/tile.png): the device with its drive, and a file manager in a browser
showing that drive's folders and samples, with files travelling both ways. Generated from a seed, so a rerun gives the
same picture.

  python3 tools/gen_tile.py [--seed N]       needs chromium (or CHROMIUM=...) for the PNG
"""
import argparse
import math
import os
import random
import shutil
import subprocess
import tempfile

W, H = 1200, 600                  # the catalog card shows its picture at 2:1
BG, INK, DIM = "#1b1c1f", "#f4f4f4", "#3a3c42"
ACCENT, AMBER, TEAL = "#d63a30", "#e0a100", "#3f8f8a"
PALETTE = ["#d63a30", "#e0a100", "#3f8f8a", "#5a6bd0", "#9b4fb0", "#2f6f4f", "#c46a2a", "#4c5560"]


def wave(rng, x, y, w, h, color, n=48):
    """A small waveform: mirrored bars around y, louder in the middle."""
    out = []
    for i in range(n):
        env = math.sin(math.pi * (i + 0.5) / n) ** 0.6
        a = h / 2 * env * (0.25 + 0.75 * rng.random())
        out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
                   % (x + i * w / n, y - a, max(w / n - 1, 1), 2 * a, color))
    return "\n".join(out)


def folder(x, y, s, color):
    return ('<path d="M %g %g h %g l %g %g h %g v %g h %g z" fill="%s"/>'
            % (x, y, s * 0.4, s * 0.1, s * 0.12, s * 0.5, s * 0.66, -s, color))


def doc(rng, x, y, w, h, color):
    """A sample file: a page with a folded corner and a waveform on it."""
    f = w * 0.28
    return "\n".join([
        '<path d="M %g %g h %g l %g %g v %g h %g z" fill="#2b2d33" stroke="%s" stroke-width="1.5"/>'
        % (x, y, w - f, f, f, h - f, -w, color),
        '<path d="M %g %g v %g h %g" fill="none" stroke="%s" stroke-width="1.5"/>' % (x + w - f, y, f, f, color),
        wave(rng, x + w * 0.14, y + h * 0.62, w * 0.72, h * 0.42, color, n=9)])


def device(rng, dx, dy, dw, dh):
    """The device: a screen listing a drive's sample folder, pads and knobs below."""
    o = ['<rect x="%g" y="%g" width="%g" height="%g" rx="14" fill="#2b2d33" stroke="#44474e" stroke-width="2"/>'
         % (dx - 22, dy - 22, dw + 44, dh + 230)]
    o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#0e0f11"/>' % (dx, dy, dw, dh))
    o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#26282d"/>' % (dx, dy, dw, 22))
    o.append('<rect x="%g" y="%g" width="%g" height="9" rx="2" fill="%s"/>' % (dx + 10, dy + 7, dw * 0.3, DIM))
    for i in range(5):                                       # the browser page of the device: rows of files
        ry = dy + 32 + i * 21
        sel = i == 2
        if sel:
            o.append('<rect x="%g" y="%g" width="%g" height="19" fill="%s" opacity=".35"/>' % (dx + 4, ry - 2, dw - 8, TEAL))
        if i < 2:
            o.append(folder(dx + 12, ry + 1, 15, AMBER))
        else:
            o.append('<rect x="%g" y="%g" width="11" height="14" rx="1" fill="%s"/>' % (dx + 14, ry + 1, TEAL if sel else "#5c6068"))
        o.append('<rect x="%g" y="%g" width="%g" height="7" rx="2" fill="%s"/>'
                 % (dx + 36, ry + 4, dw * rng.uniform(0.25, 0.5), INK if sel else DIM))
    o.append(wave(rng, dx + dw * 0.62, dy + 32 + 2 * 21 + 8, dw * 0.32, 14, TEAL, n=22))
    px, py, pw = dx + 6, dy + dh + 22, 38                    # pads
    for r in range(3):
        for c in range(4):
            col = rng.choice(PALETTE) if rng.random() < 0.3 else "#44474e"
            o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="4" fill="%s"/>'
                     % (px + c * (pw + 8), py + r * (pw + 8), pw, pw, col))
    for i in range(4):                                       # knobs
        kx, ky = dx + dw - 52 + (i % 2) * 44, py + 20 + (i // 2) * 48
        ang = rng.uniform(-2.3, 2.3)
        o.append('<circle cx="%g" cy="%g" r="16" fill="#1b1c1f" stroke="#5c6068" stroke-width="2"/>' % (kx, ky))
        o.append('<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="3" stroke-linecap="round"/>'
                 % (kx, ky, kx + 11 * math.sin(ang), ky - 11 * math.cos(ang), INK))
    return "\n".join(o)


def browser(rng, bx, by, bw, bh):
    """A file manager in a browser: a sidebar of drives, a grid of folders and samples, an upload in progress."""
    o = ['<rect x="%g" y="%g" width="%g" height="%g" rx="10" fill="#2b2d33" stroke="#44474e" stroke-width="2"/>'
         % (bx - 10, by - 46, bw + 20, bh + 56)]
    for i, c in enumerate((ACCENT, AMBER, TEAL)):
        o.append('<circle cx="%g" cy="%g" r="6" fill="%s"/>' % (bx + 10 + i * 20, by - 23, c))
    o.append('<rect x="%g" y="%g" width="%g" height="24" rx="12" fill="#1b1c1f"/>' % (bx + 80, by - 35, bw - 90))
    o.append('<text x="%g" y="%g" font-family="DejaVu Sans Mono, monospace" font-size="14" fill="#9a9ca3">'
             'localhost:6740</text>' % (bx + 98, by - 18))
    o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#0e0f11"/>' % (bx, by, bw, bh))
    sw = bw * 0.24                                           # sidebar: drives, one selected, with a fill gauge
    o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="#17181b"/>' % (bx, by, sw, bh))
    for i in range(3):
        y = by + 22 + i * 44
        if i == 0:
            o.append('<rect x="%g" y="%g" width="%g" height="38" rx="4" fill="%s" opacity=".3"/>' % (bx + 6, y - 8, sw - 12, TEAL))
        o.append('<rect x="%g" y="%g" width="18" height="12" rx="2" fill="none" stroke="%s" stroke-width="2"/>'
                 % (bx + 14, y, INK if i == 0 else "#7a7d84"))
        o.append('<rect x="%g" y="%g" width="%g" height="7" rx="2" fill="%s"/>' % (bx + 42, y + 2, sw * 0.42, INK if i == 0 else DIM))
        o.append('<rect x="%g" y="%g" width="%g" height="4" rx="2" fill="%s"/>' % (bx + 14, y + 20, sw - 28, DIM))
        o.append('<rect x="%g" y="%g" width="%g" height="4" rx="2" fill="%s"/>'
                 % (bx + 14, y + 20, (sw - 28) * rng.uniform(0.2, 0.8), AMBER if i == 0 else "#5c6068"))
    gx = bx + sw + 18                                        # breadcrumb and toolbar
    o.append('<rect x="%g" y="%g" width="%g" height="8" rx="2" fill="%s"/>' % (gx, by + 16, bw * 0.3, DIM))
    for i, c in enumerate((AMBER, "#44474e", "#44474e")):
        o.append('<rect x="%g" y="%g" width="34" height="18" rx="4" fill="%s"/>' % (bx + bw - 130 + i * 40, by + 11, c))
    o.append('<path d="M %g %g l 6 -6 l 6 6 M %g %g v 9" fill="none" stroke="#1b1c1f" stroke-width="2"/>'
             % (bx + bw - 119, by + 22, bx + bw - 113, by + 16))
    cw, ch, cols = (bw - sw - 36) / 4, 92, 4                 # grid: two folders, then samples
    for k in range(8):
        r, c = divmod(k, cols)
        x, y = gx + c * cw, by + 46 + r * (ch + 10)
        o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="6" fill="#1f2024"/>' % (x, y, cw - 12, ch))
        if k < 2:
            o.append(folder(x + (cw - 12) / 2 - 22, y + 18, 44, AMBER))
        else:
            o.append(doc(rng, x + (cw - 12) / 2 - 17, y + 12, 34, 44, rng.choice((TEAL, "#5a6bd0", "#c46a2a", "#9b4fb0"))))
        o.append('<rect x="%g" y="%g" width="%g" height="6" rx="2" fill="%s"/>' % (x + 10, y + ch - 20, (cw - 32) * rng.uniform(0.5, 0.9), DIM))
    uy = by + bh - 34                                        # an upload, part way
    o.append('<rect x="%g" y="%g" width="%g" height="24" rx="5" fill="#26282d"/>' % (gx, uy, bw - sw - 36))
    o.append('<path d="M %g %g l 5 -5 l 5 5 M %g %g v 9" fill="none" stroke="%s" stroke-width="2"/>'
             % (gx + 8, uy + 14, gx + 13, uy + 9, AMBER))
    o.append('<rect x="%g" y="%g" width="%g" height="6" rx="3" fill="%s"/>' % (gx + 26, uy + 9, bw - sw - 76, DIM))
    o.append('<rect x="%g" y="%g" width="%g" height="6" rx="3" fill="%s"/>' % (gx + 26, uy + 9, (bw - sw - 76) * 0.62, AMBER))
    return "\n".join(o)


def tile(seed):
    rng = random.Random(seed)
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">' % (W, H, W, H),
         '<rect width="%d" height="%d" fill="%s"/>' % (W, H, BG)]
    for gx in range(12, W, 24):          # faint dot grid
        for gy in range(12, H, 24):
            o.append('<circle cx="%d" cy="%d" r="1" fill="#2a2c31"/>' % (gx, gy))
    dx, dy, dw, dh = 92, 130, 290, 140
    o.append(device(rng, dx, dy, dw, dh))
    bx, by, bw, bh = 610, 130, 530, 340
    o.append(browser(rng, bx, by, bw, bh))

    # files travelling: uploads (amber) from the browser to the device along the top arc, downloads (teal) back
    x0, x1 = dx + dw + 40, bx - 30
    for k, (col, y0, bend, toward_device) in enumerate(((AMBER, 220, -70, True), (TEAL, 330, 60, False))):
        sx, ex = (x1, x0) if toward_device else (x0, x1)
        mx, my = (x0 + x1) / 2, y0 + bend
        o.append('<path d="M %g %g Q %g %g %g %g" fill="none" stroke="%s" stroke-width="2" stroke-dasharray="6 7" opacity=".7"/>'
                 % (sx, y0, mx, my, ex, y0, col))
        o.append('<path d="M %g %g l %g -7 l 0 14 z" fill="%s" opacity=".9"/>'
                 % (ex, y0, 12 if toward_device else -12, col))
        for t, s in ((0.3, 0.8), (0.62, 1.0)):
            px = (1 - t) ** 2 * sx + 2 * (1 - t) * t * mx + t * t * ex
            py = (1 - t) ** 2 * y0 + 2 * (1 - t) * t * my + t * t * y0
            w, h = 30 * s, 38 * s
            o.append(doc(rng, px - w / 2, py - h / 2, w, h, col))
    o.append("</svg>")
    return "\n".join(o)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=6740)
    a = ap.parse_args()
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs")
    os.makedirs(root, exist_ok=True)
    svg = os.path.join(root, "tile.svg")
    with open(svg, "w") as f:
        f.write(tile(a.seed))
    chrome = os.environ.get("CHROMIUM") or shutil.which("chromium") or shutil.which("chromium-browser")
    if not chrome:
        print("wrote %s (no chromium for the PNG)" % svg)
        return
    with tempfile.TemporaryDirectory() as tmp:
        page = os.path.join(tmp, "t.html")
        with open(page, "w") as f:
            f.write('<html><body style="margin:0">%s</body></html>' % open(svg).read())
        png = os.path.abspath(os.path.join(root, "tile.png"))
        subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--user-data-dir=" + tmp,
                        "--window-size=%d,%d" % (W, H), "--screenshot=" + png, "file://" + page],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("wrote %s and %s" % (svg, png))


if __name__ == "__main__":
    main()
