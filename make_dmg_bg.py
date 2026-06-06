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
    img = Image.new("RGBA", (W, H), (0, 0, 0, 255))
    d   = ImageDraw.Draw(img)

    # ── Dark gradient background ─────────────────────────────────────────────
    top_col    = (18, 20, 28)
    bottom_col = (30, 32, 44)
    for y in range(H):
        t = y / H
        r = int(top_col[0] + (bottom_col[0] - top_col[0]) * t)
        g = int(top_col[1] + (bottom_col[1] - top_col[1]) * t)
        b = int(top_col[2] + (bottom_col[2] - top_col[2]) * t)
        d.line([(0, y), (W, y)], fill=(r, g, b))

    # ── Subtle grid lines ────────────────────────────────────────────────────
    grid_img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid_img)
    grid_col = (255, 255, 255, 10)
    for x in range(0, W, 30):
        gd.line([(x, 0), (x, H)], fill=grid_col)
    for y in range(0, H, 30):
        gd.line([(0, y), (W, y)], fill=grid_col)
    img = Image.alpha_composite(img.convert("RGBA"), grid_img)
    d   = ImageDraw.Draw(img)

    # ── Soft orange glow behind the app icon ─────────────────────────────────
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd2  = ImageDraw.Draw(glow)
    r = ICON_SIZE + 20
    gd2.ellipse([APP_X - r, APP_Y - r, APP_X + r, APP_Y + r],
                fill=(255, 140, 0, 32))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=42))
    img  = Image.alpha_composite(img, glow)
    d    = ImageDraw.Draw(img)

    # ── Legible label backdrops under each icon ───────────────────────────────
    # Finder renders the icon label (filename) just below the icon image.
    # A subtle pill-shaped dark overlay improves contrast on the grid background.
    label_h  = 36   # height of the backdrop strip
    label_w  = 148  # width (wider than longest label text)
    label_y  = APP_Y + ICON_SIZE // 2 + 2   # just below icon bottom
    for cx in (APP_X, DST_X):
        backdrop = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        bd = ImageDraw.Draw(backdrop)
        bd.rounded_rectangle(
            [cx - label_w // 2, label_y,
             cx + label_w // 2, label_y + label_h],
            radius=8, fill=(0, 0, 0, 120)
        )
        backdrop = backdrop.filter(ImageFilter.GaussianBlur(radius=3))
        img = Image.alpha_composite(img, backdrop)
    d = ImageDraw.Draw(img)

    # ── Arrow between icons ───────────────────────────────────────────────────
    ax     = (APP_X + DST_X) // 2
    ay     = APP_Y
    half   = (DST_X - APP_X) // 2 - ICON_SIZE // 2 - 8
    arr_col = (255, 255, 255, 110)
    shaft_w = 3
    d.rectangle([ax - half, ay - shaft_w, ax + half - 14, ay + shaft_w], fill=arr_col)
    d.polygon([(ax + half - 14, ay - 12),
               (ax + half,      ay),
               (ax + half - 14, ay + 12)], fill=arr_col)

    # ── Bottom separator + footer text ───────────────────────────────────────
    sep_y = H - 68
    d.line([(0, sep_y), (W, sep_y)], fill=(255, 255, 255, 22))

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
    # Clamp to stay within padded bounds
    tx = max(pad, (W - tw) // 2)
    d.text((tx, ty), title, font=font_title, fill=(255, 255, 255, 220))

    sy = ty + 26
    bb2 = d.textbbox((0, 0), sub, font=font_sub)
    sw = bb2[2] - bb2[0]
    sx = max(pad, (W - sw) // 2)
    d.text((sx, sy), sub, font=font_sub, fill=(180, 180, 200, 170))

    img = img.convert("RGB")
    img.save(out_path, "PNG")
    print(f"  DMG background: {out_path} ({W}x{H})")


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dmg_background.png")
    make_background(out)
