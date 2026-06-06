#!/usr/bin/env python3
"""
make_dmg_bg.py — generate the background image for LightBurnMonitor.dmg
Produces dmg_background.png (540x380) in the project root.
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

W, H = 540, 380   # Finder window inner dimensions

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
    grid_col = (255, 255, 255, 12)
    grid_img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid_img)
    for x in range(0, W, 30):
        gd.line([(x, 0), (x, H)], fill=grid_col)
    for y in range(0, H, 30):
        gd.line([(0, y), (W, y)], fill=grid_col)
    img = Image.alpha_composite(img.convert("RGBA"), grid_img)
    d   = ImageDraw.Draw(img)

    # ── Soft glow blob behind the app icon position ──────────────────────────
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd2  = ImageDraw.Draw(glow)
    # App icon sits at x≈140, y≈190 in the Finder window
    gd2.ellipse([40, 100, 280, 290], fill=(255, 140, 0, 30))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=40))
    img  = Image.alpha_composite(img, glow)
    d    = ImageDraw.Draw(img)

    # ── Thin separator line ──────────────────────────────────────────────────
    d.line([(0, H - 56), (W, H - 56)], fill=(255, 255, 255, 18))

    # ── App title text ───────────────────────────────────────────────────────
    title = "LightBurn Monitor"
    sub   = "Drag to Applications to install"

    # Try system fonts, fall back to default
    font_title = font_sub = None
    for family in ("/System/Library/Fonts/Helvetica.ttc",
                   "/System/Library/Fonts/Arial.ttf",
                   "/Library/Fonts/Arial.ttf"):
        if os.path.exists(family):
            try:
                font_title = ImageFont.truetype(family, 26)
                font_sub   = ImageFont.truetype(family, 14)
            except Exception:
                pass
            break

    if font_title is None:
        font_title = ImageFont.load_default()
        font_sub   = ImageFont.load_default()

    # Title centred in the lower strip
    ty = H - 48
    bb = d.textbbox((0, 0), title, font=font_title)
    tw = bb[2] - bb[0]
    d.text(((W - tw) // 2, ty), title,
           font=font_title, fill=(255, 255, 255, 220))

    by = ty + 30
    bb2 = d.textbbox((0, 0), sub, font=font_sub)
    sw = bb2[2] - bb2[0]
    d.text(((W - sw) // 2, by), sub,
           font=font_sub, fill=(180, 180, 200, 160))

    # ── Arrow between icon and Applications ──────────────────────────────────
    ax, ay = W // 2, 185   # midpoint
    arr_col = (255, 255, 255, 80)
    shaft_w = 3
    d.rectangle([ax - 28, ay - shaft_w, ax + 18, ay + shaft_w], fill=arr_col)
    # arrowhead
    d.polygon([(ax + 18, ay - 10), (ax + 38, ay), (ax + 18, ay + 10)], fill=arr_col)

    img = img.convert("RGB")
    img.save(out_path, "PNG")
    print(f"  DMG background: {out_path} ({W}x{H})")


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dmg_background.png")
    make_background(out)
