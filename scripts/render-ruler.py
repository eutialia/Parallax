#!/usr/bin/env python3
"""Measure a RenderPreview snapshot in points, without eyeballing.

Pairs with the `previewRuler(...)` helper (PreviewRuler.swift): the preview
draws pure-red 1pt rules at known pt insets, this script finds them, derives
nothing from them but reports their positions, and converts every measurement
to points via --pt-width (the preview's `.fixedLayout` width — do NOT trust
the @Nx suffix in the snapshot filename, it lies).

Typical loop (ONE render, many measurements):
  1. Pin the preview:  #Preview("…", traits: .fixedLayout(width: 393, height: 740))
     and add `.previewRuler(trailing: AppLayout.contentHMargin(idiom: .compact))`.
  2. RenderPreview (dark mode gives the best platter/edge contrast).
  3. python3 scripts/render-ruler.py --pt-width 393              # summary + rulers
  4. python3 scripts/render-ruler.py --pt-width 393 --scan-row auto   # run-lengths
  5. Only if the question is qualitative ("does it READ right"), crop for eyes:
     python3 scripts/render-ruler.py --crop tr --size 320x440 --zoom 3 --out /tmp/look.png

With no path argument the newest snapshot in Xcode's RenderPreview artifacts
directory is used, so there is no cp step.

Precision note: a `.fixedLayout` canvas can render a few pt wider than declared
(393 → 398 observed), so absolute pt values carry that error. The RULER is the
trustworthy reference: it is drawn at a known token's inset, so "does edge X
land on the ruler" is exact regardless of canvas slop.

Output bands in --scan-row: W bright(>180) / m mid(>55) / . dim(>23) / ' ' background.
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile


def artifacts_dir() -> str:
    tmp = subprocess.run(
        ["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True
    ).stdout.strip()
    return os.path.join(tmp, "ActionArtifacts", "default", "RenderPreview")


def newest_snapshot() -> str:
    d = artifacts_dir()
    pngs = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".png")]
    if not pngs:
        sys.exit(f"no snapshots in {d} — run RenderPreview first")
    return max(pngs, key=os.path.getmtime)


class Bitmap:
    """PNG → BMP via sips (always present on macOS), then raw pixel access."""

    def __init__(self, png_path: str):
        self.path = png_path
        with tempfile.NamedTemporaryFile(suffix=".bmp", delete=False) as tf:
            bmp_path = tf.name
        try:
            r = subprocess.run(
                ["sips", "-s", "format", "bmp", png_path, "--out", bmp_path],
                capture_output=True, text=True,
            )
            if r.returncode != 0:
                sys.exit(f"sips failed: {r.stderr.strip()}")
            with open(bmp_path, "rb") as f:
                self.data = f.read()
        finally:
            os.unlink(bmp_path)
        self.offset = struct.unpack_from("<I", self.data, 10)[0]
        self.width = struct.unpack_from("<i", self.data, 18)[0]
        raw_h = struct.unpack_from("<i", self.data, 22)[0]
        self.height = abs(raw_h)
        self.bottom_up = raw_h > 0
        self.bpp = struct.unpack_from("<H", self.data, 28)[0]
        if self.bpp not in (24, 32):
            sys.exit(f"unsupported BMP bpp {self.bpp}")
        self.row_size = ((self.width * self.bpp // 8 + 3) // 4) * 4

    def px(self, x: int, y: int):
        ry = (self.height - 1 - y) if self.bottom_up else y
        i = self.offset + ry * self.row_size + x * (self.bpp // 8)
        d = self.data
        return d[i + 2], d[i + 1], d[i]  # r, g, b


def is_ruler_red(rgb) -> bool:
    r, g, b = rgb
    return r > 180 and g < 90 and b < 90


def group_runs(values):
    """[(start, end)] for consecutive ints."""
    runs = []
    for v in sorted(values):
        if runs and v == runs[-1][1] + 1:
            runs[-1][1] = v
        else:
            runs.append([v, v])
    return runs


def find_rulers(bm: Bitmap):
    """Columns/rows that are ≥60% ruler-red across the cross axis."""
    cols, rows = [], []
    ys = range(0, bm.height, max(1, bm.height // 200))
    for x in range(bm.width):
        hits = sum(1 for y in ys if is_ruler_red(bm.px(x, y)))
        if hits >= 0.6 * len(list(ys)):
            cols.append(x)
    xs = range(0, bm.width, max(1, bm.width // 200))
    for y in range(bm.height):
        hits = sum(1 for x in xs if is_ruler_red(bm.px(x, y)))
        if hits >= 0.6 * len(list(xs)):
            rows.append(y)
    return group_runs(cols), group_runs(rows)


def band(lum: int) -> str:
    return "W" if lum > 180 else "m" if lum > 55 else "." if lum > 23 else " "


def scan_row(bm: Bitmap, y: int, scale: float, x0: int, x1: int):
    runs, prev = [], None
    for x in range(x0, x1):
        r, g, b = bm.px(x, y)
        lum = (r + g + b) // 3
        bd = band(lum)
        if bd != prev:
            runs.append([bd, x, x])
            prev = bd
        else:
            runs[-1][2] = x
    visible = [r for r in runs if r[0] != " " or (r[2] - r[1]) > 2]
    print(f"row {y} (y={pt(y, scale)}), x∈[{x0},{x1}):")
    print("  " + "".join(f"{b}[{a}-{c}]" for b, a, c in visible))
    print("  runs ≥4px (band, span, width, outer edges):")
    for b, a, c in runs:
        if b == " " or c - a < 3:
            continue
        print(
            f"    {b} x={a}-{c}  w={pt(c - a + 1, scale)}"
            f"  left@{pt(a, scale)}  right@{pt(bm.width - 1 - c, scale)}-from-right"
        )


def auto_glyph_row(bm: Bitmap, x_frac: float = 0.55) -> int:
    """Median row with bright pixels in the right part of the top quarter."""
    rows = []
    for y in range(bm.height // 4):
        if any(min(bm.px(x, y)) > 180 for x in range(int(bm.width * x_frac), bm.width, 2)):
            rows.append(y)
    if not rows:
        sys.exit("no bright glyph rows found in the top quarter")
    return rows[len(rows) // 2]


def pt(v: float, scale: float) -> str:
    return f"{v / scale:.1f}pt" if scale else f"{v}px"


def crop(args, src: str):
    w, h = (int(v) for v in args.size.split("x"))
    bm = Bitmap(src)
    offsets = {
        "tl": (0, 0),
        "tr": (0, bm.width - w),
        "bl": (bm.height - h, 0),
        "br": (bm.height - h, bm.width - w),
    }
    oy, ox = offsets[args.crop]
    out = args.out or "/tmp/render-crop.png"
    subprocess.run(
        ["sips", "-c", str(h), str(w), "--cropOffset", str(oy), str(ox), src, "--out", out],
        capture_output=True,
    )
    if args.zoom > 1:
        subprocess.run(["sips", "-z", str(h * args.zoom), str(w * args.zoom), out], capture_output=True)
    print(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("png", nargs="?", help="snapshot path (default: newest RenderPreview artifact)")
    p.add_argument("--pt-width", type=float, help="preview canvas width in pt (.fixedLayout width) → enables pt output")
    p.add_argument("--scan-row", help="'auto' (find toolbar glyphs), a pixel row, or a 0–1 height fraction")
    p.add_argument("--scan-from", type=float, default=0.5, help="left bound of the scan as width fraction (default 0.5)")
    p.add_argument("--crop", choices=["tl", "tr", "bl", "br"], help="write a corner crop instead of measuring")
    p.add_argument("--size", default="320x440", help="crop WxH in px (default 320x440)")
    p.add_argument("--zoom", type=int, default=3, help="crop upscale factor (default 3)")
    p.add_argument("--out", help="crop output path")
    args = p.parse_args()

    src = args.png or newest_snapshot()
    if args.crop:
        crop(args, src)
        return

    bm = Bitmap(src)
    scale = bm.width / args.pt_width if args.pt_width else 0
    print(f"{src}")
    print(f"size {bm.width}x{bm.height}px", f"scale {scale:.3f}x → canvas {pt(bm.width, scale)} wide" if scale else "(no --pt-width: px only)")

    vcols, hrows = find_rulers(bm)
    for a, b in vcols:
        print(f"ruler | vertical x={a}-{b}: {pt(a, scale)} from left, {pt(bm.width - 1 - b, scale)} from right")
    for a, b in hrows:
        print(f"ruler — horizontal y={a}-{b}: {pt(a, scale)} from top, {pt(bm.height - 1 - b, scale)} from bottom")
    if not vcols and not hrows:
        print("no red rulers found (add .previewRuler(...) to the preview)")

    if args.scan_row:
        if args.scan_row == "auto":
            y = auto_glyph_row(bm)
        else:
            v = float(args.scan_row)
            y = int(v * bm.height) if 0 < v < 1 else int(v)
        scan_row(bm, y, scale, int(bm.width * args.scan_from), bm.width)


if __name__ == "__main__":
    main()
