#!/usr/bin/env python3
"""Generate iOS apple-touch-startup-image splash PNGs from icon-512.png.

Brand-blue background with the circular logo centered (sitting slightly
above the vertical middle so it doesn't fight with the status bar's
notch / Dynamic Island).

Re-run any time the source icon changes; output paths are stable.
"""
from PIL import Image

ROOT = "/Users/felipefaraone/mybjj-app"
SRC = f"{ROOT}/icon-512.png"
BG = (0x1A, 0x5D, 0xAD)        # myBJJ brand blue

# Portrait sizes covering the iOS device matrix Apple publishes startup
# media queries for. Landscape isn't needed — manifest pins orientation
# to portrait.
SIZES = [
    (750,  1334),   # iPhone SE 3 / 8 / 6s / 7
    (1125, 2436),   # iPhone X / XS / 11 Pro
    (1170, 2532),   # iPhone 12 / 13 / 14 / 15
    (1284, 2778),   # iPhone 11 Pro Max / 12-14 Pro Max
    (1290, 2796),   # iPhone 15 Pro Max / 16 Pro Max
    (1536, 2048),   # iPad / iPad mini (9.7", 10.2")
    (2048, 2732),   # iPad Pro 12.9"
]

# Logo occupies ~28% of the shorter dimension, centered slightly above
# the vertical midpoint so the visual mass isn't pulled down by the
# home indicator on bezel-less devices.
LOGO_PCT = 0.28
LOGO_Y_OFFSET = -0.04           # fraction of height; negative = up

src = Image.open(SRC).convert("RGBA")

for w, h in SIZES:
    canvas = Image.new("RGBA", (w, h), BG + (255,))
    short = min(w, h)
    logo_sz = int(round(short * LOGO_PCT))
    logo = src.resize((logo_sz, logo_sz), Image.LANCZOS)
    x = (w - logo_sz) // 2
    y = int(round((h - logo_sz) / 2 + h * LOGO_Y_OFFSET))
    canvas.paste(logo, (x, y), logo)
    out = canvas.convert("RGB")
    path = f"{ROOT}/splash-{w}x{h}.png"
    out.save(path, optimize=True)
    print(f"  wrote {path}")
