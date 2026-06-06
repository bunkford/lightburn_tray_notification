#!/usr/bin/env python3
"""
make_dmg_bg.py — generate the background image for LightBurnMonitor.dmg
Produces dmg_background.png (620x420) in the project root.
Requires Pillow (already a project dependency via make_icon.py).
"""
import sys, subprocess, os

def _ensure_pillow():
    for extra in ([], ["--break-system-packages"], ["--user"]):
        try:
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", "--quiet", "Pillow"] + extra,
                stderr=subprocess.DEVNULL,
            )
            return
        except subprocess.CalledProcessError:
            continue

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    _ensure_pillow()
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Finder window dimensions — must match the AppleScript bounds in build.sh
W, H = 620, 420

# Icon positions inside the Finder window (set by AppleScript)
APP_X,  APP_Y  = 150, 190   # LightBurnMonitor.app icon centre
DST_X,  DST_Y  = 470, 190   # Applications alias icon centre
ICON_SIZE = 96               # Finder icon size (set in AppleScript)

def make_background(out_path: str) -> None:
    img = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d   = ImageDraw.Draw(img)

    # ── Light gradient background ─────────────────────────────────────────────
    top_col    = (245, 246, 250)   # near-white
    bottom_col = (218, 220, 232)   # light lavender-grey
    for y in range(H):
        t = y / H
        rv = int(top_col[0] + (bottom_col[0] - top_col[0]) * t)
        gv = int(top_col[1] + (bottom_col[1] - top_col[1]) * t)
        bv = int(top_col[2] + (bottom_col[2] - top_col[2]) * t)
        d.line([(0, y), (W, y)], fill=(rv, gv, bv))

    # ── Subtle dark grid lines ────────────────────────────────────────────────
    grid_img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid_img)
    grid_col = (0, 0, 0, 14)
    for x in range(0, W, 30):
        gd.line([(x, 0), (x, H)], fill=grid_col)
    for y in range(0, H, 30):
        gd.line([(0, y), (W, y)], fill=grid_col)
    img = Image.alpha_composite(img.convert("RGBA"), grid_img)
    d   = ImageDraw.Draw(img)

    # ── Soft orange glow behind the app icon ─────────────────────────────────
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd2  = ImageDraw.Draw(glow)
    gr = ICON_SIZE + 20
    gd2.ellipse([APP_X - gr, APP_Y - gr, APP_X + gr, APP_Y + gr],
                fill=(255, 140, 0, 45))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=42))
    img  = Image.alpha_composite(img, glow)
    d    = ImageDraw.Draw(img)

    # ── Arrow between icons ───────────────────────────────────────────────────
    ax     = (APP_X + DST_X) // 2
    ay     = APP_Y
    half   = (DST_X - APP_X) // 2 - ICON_SIZE // 2 - 8
    arr_col = (100, 100, 130, 200)
    shaft_w = 3
    d.rectangle([ax - half, ay - shaft_w, ax + half - 14, ay + shaft_w], fill=arr_col)
    d.polygon([(ax + half - 14, ay - 12),
               (ax + half,      ay),
               (ax + half - 14, ay + 12)], fill=arr_col)

    # ── Bottom separator + footer text ───────────────────────────────────────
    sep_y = H - 68
    d.line([(0, sep_y), (W, sep_y)], fill=(0, 0, 0, 30))

    # Footer strip — slightly darker shade
    for y in range(sep_y, H):
        t = (y - sep_y) / max(1, H - sep_y)
        rv = int(210 + (195 - 210) * t)
        gv = int(212 + (197 - 212) * t)
        bv = int(222 + (210 - 222) * t)
        d.line([(0, y), (W, y)], fill=(rv, gv, bv))

    title = "LightBurn Monitor"
    sub   = "Drag to Applications to install"

    font_title = font_sub = None
    for family in ("/System/Library/Fonts/Helvetica.ttc",
                   "/System/Library/Fonts/Arial.ttf",
                   "/Library/Fonts/Arial.ttf"):
        if os.path.exists(family):
            try:
                font_title = ImageFont.truetype(family, 22)
                font_sub   = ImageFont.truetype(family, 13)
            except Exception:
                pass
            break
    if font_title is None:
        font_title = ImageFont.load_default()
        font_sub   = ImageFont.load_default()

    pad = 24   # horizontal safe-zone padding

    ty = sep_y + 12
    bb = d.textbbox((0, 0), title, font=font_title)
    tw = bb[2] - bb[0]
    tx = max(pad, (W - tw) // 2)
    d.text((tx, ty), title, font=font_title, fill=(30, 30, 50, 235))

    sy = ty + 26
    bb2 = d.textbbox((0, 0), sub, font=font_sub)
    sw = bb2[2] - bb2[0]
    sx = max(pad, (W - sw) // 2)
    d.text((sx, sy), sub, font=font_sub, fill=(70, 70, 100, 210))

    img = img.convert("RGB")
    img.save(out_path, "PNG")
    print(f"  DMG background: {out_path} ({W}x{H})")


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dmg_background.png")
    make_background(out)
