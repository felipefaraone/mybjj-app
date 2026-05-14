#!/usr/bin/env python3
"""Regenerate icon-192.png and icon-512.png for "purpose: any".

Brand-blue square canvas with the circular myBJJ logo centered at ~70%
of canvas (15% padding on each side). iOS rounds the square corners
naturally on home-screen install (Spotify/Instagram style); Android
launchers leave the square as-is or mask it.

The 10%-padded maskable variants (icon-{192,512}-maskable.png) stay
untouched — they're correctly designed for the maskable purpose.

Source: LOGO_DATA_URI in index.html (the original 1024x1024 JPEG, even
though the data-URI is mislabeled as image/png — Pillow auto-detects).
Reading from the canonical source keeps the script idempotent across
re-runs and decouples it from any other derived icon file.
"""
import base64, io, re, sys
from PIL import Image, ImageDraw

ROOT = "/Users/felipefaraone/mybjj-app"
BG   = (0x1A, 0x5D, 0xAD)        # myBJJ brand blue
LOGO_PCT = 0.70                  # 70% of canvas → 15% padding each side

with open(f"{ROOT}/index.html", "rb") as f:
    for line in f:
        m = re.match(rb'^const LOGO_DATA_URI="data:[^,]+,([^"]+)";', line)
        if m:
            b64 = m.group(1)
            break
    else:
        sys.exit("LOGO_DATA_URI not found in index.html")

raw = base64.b64decode(b64)
src_rgb = Image.open(io.BytesIO(raw)).convert("RGB")

# The data-URI source has a square crop with the circular logo filling
# the frame on a (non-transparent) background — apply a circular alpha
# mask the same way the maskable / transparent icon generator does so
# the transparent corners show the brand-blue background through.
def circle_mask(src):
    w, h = src.size
    short = min(w, h)
    masked = Image.new("RGBA", (short, short), (0, 0, 0, 0))
    src_sq = src.crop((
        (w - short) // 2, (h - short) // 2,
        (w - short) // 2 + short, (h - short) // 2 + short,
    ))
    mask = Image.new("L", (short, short), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, short - 1, short - 1), fill=255)
    masked.paste(src_sq, (0, 0), mask)
    return masked

src = circle_mask(src_rgb)

def make(size):
    canvas = Image.new("RGBA", (size, size), BG + (255,))
    logo_sz = int(round(size * LOGO_PCT))
    logo = src.resize((logo_sz, logo_sz), Image.LANCZOS)
    off = (size - logo_sz) // 2
    canvas.paste(logo, (off, off), logo)
    canvas.convert("RGB").save(f"{ROOT}/icon-{size}.png", optimize=True)
    print(f"  wrote {ROOT}/icon-{size}.png")

for s in (192, 512):
    make(s)
