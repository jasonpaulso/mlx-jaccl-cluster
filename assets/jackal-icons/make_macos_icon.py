#!/usr/bin/env python3
"""
Crop a logo to a centered square and cut a full macOS icon set.

Usage:
    python3 make_macos_icon.py SOURCE.png [--pad 0.12] [--bg none|#RRGGBB]

Steps:
  1. Auto-detect the subject's bounding box (alpha if present, else dark pixels).
  2. Crop to a centered square around it (drops corner watermarks), with padding.
  3. Emit AppIcon.iconset/ at all required sizes + Contents.json.
  4. If run on macOS, build AppIcon.icns via iconutil.

Requires: Pillow  ->  pip install pillow
"""
import argparse, json, os, shutil, subprocess, sys
from PIL import Image

SIZES = [16, 32, 64, 128, 256, 512, 1024]  # px actually needed (1x/2x of 16..512)
CONTENTS = [  # (size_pt, scale, px)
    (16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64),
    (128, 1, 128), (128, 2, 256), (256, 1, 256), (256, 2, 512),
    (512, 1, 512), (512, 2, 1024),
]

def bbox_of_subject(im):
    """Bounding box of non-transparent (or non-white) content."""
    if im.mode in ("RGBA", "LA") and im.getchannel("A").getextrema()[0] < 255:
        bb = im.getchannel("A").getbbox()
        if bb:
            return bb
    # No usable alpha: treat near-white as background.
    gray = im.convert("L")
    # pixels darker than 240 count as subject
    mask = gray.point(lambda p: 255 if p < 240 else 0)
    return mask.getbbox()

def centered_square_crop(im, pad_frac):
    bb = bbox_of_subject(im)
    if not bb:
        bb = (0, 0, im.width, im.height)
    l, t, r, b = bb
    cx, cy = (l + r) / 2, (t + b) / 2
    side = max(r - l, b - t) * (1 + 2 * pad_frac)
    half = side / 2
    left, top = int(cx - half), int(cy - half)
    right, bottom = int(cx + half), int(cy + half)
    # If crop exceeds canvas, paste onto a transparent square instead of clamping.
    canvas = Image.new("RGBA", (int(side), int(side)), (0, 0, 0, 0))
    src = im.convert("RGBA")
    canvas.paste(src, (-left, -top), src)
    return canvas

def flatten(im, bg):
    if bg == "none":
        return im
    back = Image.new("RGBA", im.size, bg)
    back.paste(im, (0, 0), im)
    return back.convert("RGBA")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("--pad", type=float, default=0.12, help="padding as fraction of subject size")
    ap.add_argument("--bg", default="none", help="'none' for transparent, or #RRGGBB")
    ap.add_argument("--out", default="AppIcon.iconset")
    args = ap.parse_args()

    bg = "none"
    if args.bg != "none":
        h = args.bg.lstrip("#")
        bg = tuple(int(h[i:i+2], 16) for i in (0, 2, 4)) + (255,)

    im = Image.open(args.source)
    sq = centered_square_crop(im, args.pad)
    sq = flatten(sq, bg)

    # Master square for reference
    sq.resize((1024, 1024), Image.LANCZOS).save("icon_master_1024.png")

    os.makedirs(args.out, exist_ok=True)
    for pt, scale, px in CONTENTS:
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        sq.resize((px, px), Image.LANCZOS).save(os.path.join(args.out, name))

    contents = {"images": [], "info": {"version": 1, "author": "xcode"}}
    for pt, scale, px in CONTENTS:
        contents["images"].append({
            "size": f"{pt}x{pt}",
            "idiom": "mac",
            "filename": f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png",
            "scale": f"{scale}x",
        })
    with open(os.path.join(args.out, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)

    print(f"Wrote {args.out}/ (10 PNGs + Contents.json) and icon_master_1024.png")

    if sys.platform == "darwin" and shutil.which("iconutil"):
        subprocess.run(["iconutil", "-c", "icns", args.out, "-o", "AppIcon.icns"], check=True)
        print("Built AppIcon.icns")
    else:
        print("Skipped .icns (needs macOS iconutil). Run on your Mac:")
        print(f"    iconutil -c icns {args.out} -o AppIcon.icns")

if __name__ == "__main__":
    main()
