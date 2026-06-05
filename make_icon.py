#!/usr/bin/env python3
"""
make_icon.py — generate AppIcon.icns for LightBurnMonitor.app
Requires Pillow (auto-installed if absent) and macOS iconutil.
Run from the project root:  python3 make_icon.py
"""
import subprocess, sys, os, shutil

# ── Ensure Pillow is available ────────────────────────────────────────────────
def _install_pillow():
    for extra in ([], ["--break-system-packages"], ["--user"]):
        try:
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", "--quiet", "Pillow"] + extra,
                stderr=subprocess.DEVNULL,
            )
            return
        except subprocess.CalledProcessError:
            continue
    raise RuntimeError("Could not install Pillow — run: pip3 install Pillow")

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    print("  Installing Pillow...")
    _install_pillow()
    from PIL import Image, ImageDraw, ImageFilter

# (pixel_size, [iconset_filename, ...])
# Each rendered size maps to one or two iconset filenames (1x and @2x variants).
SIZE_MAP = [
    (16,   ["icon_16x16.png"]),
    (32,   ["icon_32x32.png",  "icon_16x16@2x.png"]),
    (64,   ["icon_32x32@2x.png"]),
    (128,  ["icon_128x128.png"]),
    (256,  ["icon_256x256.png", "icon_128x128@2x.png"]),
    (512,  ["icon_512x512.png", "icon_256x256@2x.png"]),
    (1024, ["icon_512x512@2x.png"]),
]


def draw_icon(size: int) -> "Image.Image":
    """
    Renders the LightBurnMonitor icon at the requested pixel size.

    Design: dark squircle background, a laser-cutter gantry bar at the top
    with a nozzle/lens below it, an orange beam tapering downward, and a warm
    impact glow at the workpiece.  A subtle glow-pass (blur composite) adds
    depth for sizes ≥ 32 px.
    """
    S = float(size)
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d   = ImageDraw.Draw(img)

    # ── Background: dark squircle ─────────────────────────────────────────
    pad = S * 0.04
    rad = S * 0.22
    d.rounded_rectangle([pad, pad, S - pad, S - pad],
                        radius=rad, fill=(22, 24, 30, 255))

    cx = S / 2.0

    # ── Gantry bar (horizontal rail, top third) ───────────────────────────
    bar_h  = S * 0.10
    bar_y  = S * 0.18
    bar_x0 = S * 0.20
    bar_x1 = S * 0.80
    bar_r  = bar_h * 0.38
    d.rounded_rectangle([bar_x0, bar_y, bar_x1, bar_y + bar_h],
                        radius=bar_r, fill=(72, 78, 96, 255))
    # top-edge highlight
    hl_h = bar_h * 0.28
    d.rounded_rectangle([bar_x0 + S * 0.02, bar_y + S * 0.01,
                         bar_x1 - S * 0.02, bar_y + hl_h],
                        radius=bar_r * 0.5, fill=(108, 116, 138, 200))

    # ── Nozzle block (hangs below bar centre) ─────────────────────────────
    noz_w = S * 0.10
    noz_h = S * 0.09
    noz_y = bar_y + bar_h
    d.rounded_rectangle([cx - noz_w / 2, noz_y,
                         cx + noz_w / 2, noz_y + noz_h],
                        radius=noz_w * 0.15, fill=(58, 62, 76, 255))

    # Lens dot inside nozzle (bright amber)
    ld = S * 0.038
    ly = noz_y + noz_h * 0.48
    d.ellipse([cx - ld, ly - ld, cx + ld, ly + ld], fill=(255, 220, 70, 255))

    # ── Laser beam (trapezoid, nozzle → workpiece) ────────────────────────
    beam_top_y = noz_y + noz_h
    beam_bot_y = S * 0.81
    btop_w     = noz_w * 0.22   # narrow at source
    bbot_w     = S * 0.20       # wide at workpiece

    def beam_poly(tw, bw):
        return [(cx - tw, beam_top_y), (cx + tw, beam_top_y),
                (cx + bw, beam_bot_y), (cx - bw, beam_bot_y)]

    d.polygon(beam_poly(btop_w * 5.5, bbot_w * 1.75), fill=(255, 90,  0,  40))  # outer glow
    d.polygon(beam_poly(btop_w * 2.5, bbot_w),         fill=(255, 130, 15, 185)) # main
    d.polygon(beam_poly(btop_w,       bbot_w * 0.36),  fill=(255, 238, 100, 240)) # core

    # ── Impact glow (ellipse at workpiece) ────────────────────────────────
    gr  = bbot_w * 1.05
    gy  = beam_bot_y + S * 0.01
    grc = gr * 0.40
    d.ellipse([cx - gr,  gy - gr  * 0.28, cx + gr,  gy + gr  * 0.28],
              fill=(215, 75, 0, 155))
    d.ellipse([cx - grc, gy - grc * 0.32, cx + grc, gy + grc * 0.32],
              fill=(255, 218, 90, 205))

    # ── Glow pass: blur the existing image and composite behind ──────────
    if size >= 32:
        blur_r = max(1, int(S * 0.022))
        glow   = img.filter(ImageFilter.GaussianBlur(blur_r))
        img    = Image.alpha_composite(glow, img)

    return img


def main():
    root    = os.path.dirname(os.path.abspath(__file__))
    iconset = os.path.join(root, "AppIcon.iconset")
    icns    = os.path.join(root, "AppIcon.icns")
    os.makedirs(iconset, exist_ok=True)

    print("==> Generating icon sizes...")
    for px_size, names in SIZE_MAP:
        rendered = draw_icon(px_size)
        for name in names:
            rendered.save(os.path.join(iconset, name), "PNG")
        print(f"    {px_size}x{px_size}  →  {', '.join(names)}")

    print("==> Running iconutil...")
    subprocess.check_call(["iconutil", "-c", "icns", iconset, "-o", icns])
    shutil.rmtree(iconset)
    print("==> AppIcon.icns created.")


if __name__ == "__main__":
    main()
