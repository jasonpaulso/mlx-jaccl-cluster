#!/usr/bin/env python3
"""
Build a macOS AppIcon set from the jackal artwork.

Tailored to these Gemini exports: the "transparent" file is actually fully
opaque (checkerboard is painted in), and both backgrounds read as "subject"
under a near-white test, so we detect the jackal by its near-BLACK pixels and
composite the black art onto a clean solid background.

Usage:
    python3 make_icon.py [SOURCE.png] [--pad 0.18] [--bg #FFFFFF]
"""
import argparse, json, os, shutil, subprocess, sys
from PIL import Image

CONTENTS = [  # (size_pt, scale, px)
    (16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64),
    (128, 1, 128), (128, 2, 256), (256, 1, 256), (256, 2, 512),
    (512, 1, 512), (512, 2, 1024),
]

# Levels: source luminance below BLACK_IN -> pure art color; above WHITE_IN ->
# pure background. Between, a smooth ramp that keeps antialiased edges.
BLACK_IN, WHITE_IN = 50, 190

def black_bbox(im, thr=100):
    g = im.convert("L")
    return g.point(lambda p: 255 if p < thr else 0).getbbox()

def build_master(src, pad_frac, bg):
    im = Image.open(src).convert("RGB")
    bb = black_bbox(im) or (0, 0, im.width, im.height)
    l, t, r, b = bb
    cx, cy = (l + r) / 2, (t + b) / 2
    side = max(r - l, b - t) * (1 + 2 * pad_frac)
    half = side / 2
    box = (int(cx - half), int(cy - half), int(cx + half), int(cy + half))

    # Crop to square on a white pad (overflow -> 255 -> becomes background).
    canvas = Image.new("RGB", (int(side), int(side)), (255, 255, 255))
    canvas.paste(im, (-box[0], -box[1]))

    # Levels on luminance, then colorize: t=0 -> black art, t=1 -> bg color.
    lum = canvas.convert("L")
    scale = 255.0 / (WHITE_IN - BLACK_IN)
    ramp = lum.point(lambda p: 0 if p <= BLACK_IN else (255 if p >= WHITE_IN
                     else int((p - BLACK_IN) * scale)))
    black = Image.new("RGB", canvas.size, (0, 0, 0))
    back = Image.new("RGB", canvas.size, bg)
    master = Image.composite(back, black, ramp)  # ramp=255 -> back, 0 -> black
    return master.resize((1024, 1024), Image.LANCZOS)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", nargs="?",
                    default="Gemini_Generated_Image_l0qvwal0qvwal0qv.png")
    ap.add_argument("--pad", type=float, default=0.18)
    ap.add_argument("--bg", default="#FFFFFF")
    ap.add_argument("--out", default="AppIcon.iconset")
    args = ap.parse_args()

    h = args.bg.lstrip("#")
    bg = tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

    master = build_master(args.source, args.pad, bg)
    master.save("icon_master_1024.png")

    os.makedirs(args.out, exist_ok=True)
    for pt, scale, px in CONTENTS:
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(args.out, name))

    contents = {"images": [{
        "size": f"{pt}x{pt}", "idiom": "mac",
        "filename": f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png",
        "scale": f"{scale}x",
    } for pt, scale, px in CONTENTS], "info": {"version": 1, "author": "xcode"}}
    with open(os.path.join(args.out, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
    print(f"Wrote {args.out}/ (10 PNGs + Contents.json) and icon_master_1024.png")

    if sys.platform == "darwin" and shutil.which("iconutil"):
        subprocess.run(["iconutil", "-c", "icns", args.out, "-o", "AppIcon.icns"],
                       check=True)
        print("Built AppIcon.icns")

if __name__ == "__main__":
    main()
