#!/usr/bin/env python3
"""Generate og-image.png — 1200x630 Open Graph preview.

Brand-blue canvas with the circular logo, "MyBJJ" wordmark, and the
tagline below. Used by Facebook / WhatsApp / iMessage / Slack / Twitter
preview cards.

Source: the same LOGO_DATA_URI in index.html that the splash and app-
icon generators use. Re-run after any logo update.
"""
import base64, io, os, re, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = "/Users/felipefaraone/mybjj-app"
BG   = (0x1A, 0x5D, 0xAD)          # myBJJ brand blue
W, H = 1200, 630                   # OG standard

# -- Read source logo ---------------------------------------------------------
with open(f"{ROOT}/index.html", "rb") as f:
    for line in f:
        m = re.match(rb'^const LOGO_DATA_URI="data:[^,]+,([^"]+)";', line)
        if m:
            b64 = m.group(1)
            break
    else:
        sys.exit("LOGO_DATA_URI not found in index.html")

src_rgb = Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGB")

# -- Circle-mask the logo so the corners stay brand-blue ----------------------
def circle_mask(src):
    w, h = src.size
    short = min(w, h)
    src_sq = src.crop((
        (w - short) // 2, (h - short) // 2,
        (w - short) // 2 + short, (h - short) // 2 + short,
    ))
    mask = Image.new("L", (short, short), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, short - 1, short - 1), fill=255)
    masked = Image.new("RGBA", (short, short), (0, 0, 0, 0))
    masked.paste(src_sq, (0, 0), mask)
    return masked

logo = circle_mask(src_rgb)

# -- Font discovery -----------------------------------------------------------
def load_font(candidates, size):
    for path in candidates:
        if path and os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()

WORD_FONTS = [
    "/System/Library/Fonts/Supplemental/Impact.ttf",
    "/Library/Fonts/Impact.ttf",
    "/System/Library/Fonts/Helvetica.ttc",   # bold-ish at large sizes
]
TAG_FONTS = [
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
]

word_font = load_font(WORD_FONTS, 110)
tag_font  = load_font(TAG_FONTS, 32)

# -- Compose ------------------------------------------------------------------
canvas = Image.new("RGBA", (W, H), BG + (255,))

LOGO_SZ = 240
logo_resized = logo.resize((LOGO_SZ, LOGO_SZ), Image.LANCZOS)
canvas.paste(logo_resized, ((W - LOGO_SZ) // 2, 100), logo_resized)

draw = ImageDraw.Draw(canvas)

def draw_centered(text, font, fill, y):
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    draw.text(((W - text_w) // 2, y), text, fill=fill, font=font)

draw_centered("MyBJJ", word_font, (255, 255, 255, 255), 365)
draw_centered("Brazilian Jiu-Jitsu Team — Neutral Bay",
              tag_font, (255, 255, 255, 200), 510)

canvas.convert("RGB").save(f"{ROOT}/og-image.png", optimize=True)
print(f"  wrote {ROOT}/og-image.png ({W}x{H})")
