#!/usr/bin/env python3
"""Generates Resources/AppIcon.iconset from scratch. Run once; build.sh turns it into AppIcon.icns."""
import os
from PIL import Image, ImageDraw

S = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon.iconset")

DEEP = (7, 30, 38)
MID = (16, 50, 60)
AMBER = (242, 179, 61)
PAPER = (232, 241, 242)


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def build():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Vertical gradient body.
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        t = y / (S - 1)
        gd.line([(0, y), (S, y)], fill=(
            int(MID[0] + (DEEP[0] - MID[0]) * t),
            int(MID[1] + (DEEP[1] - MID[1]) * t),
            int(MID[2] + (DEEP[2] - MID[2]) * t),
            255))
    img.paste(grad, (0, 0), rounded_mask(S, int(S * 0.2237)))

    d = ImageDraw.Draw(img)

    # Text bars: the thing being captured.
    bar_h = int(S * 0.062)
    gap = int(S * 0.055)
    widths = [0.46, 0.36, 0.42, 0.24]
    left = int(S * 0.30)
    top = int(S * 0.335)
    for i, w in enumerate(widths):
        y = top + i * (bar_h + gap)
        fill = AMBER if i == 0 else PAPER
        alpha = 255 if i == 0 else 210 - i * 26
        d.rounded_rectangle([left, y, left + int(S * w), y + bar_h],
                            radius=bar_h // 2, fill=fill[:3] + (alpha,))

    # Corner brackets: the selection.
    inset = int(S * 0.185)
    arm = int(S * 0.145)
    t = int(S * 0.052)
    a, b = inset, S - inset
    r = t // 2
    for (cx, cy, dx, dy) in ((a, a, 1, 1), (b, a, -1, 1), (a, b, 1, -1), (b, b, -1, -1)):
        d.line([(cx, cy), (cx + dx * arm, cy)], fill=AMBER, width=t)
        d.line([(cx, cy), (cx, cy + dy * arm)], fill=AMBER, width=t)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=AMBER)

    os.makedirs(OUT, exist_ok=True)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        img.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, f"icon_{px}x{px}.png"))
    # Retina @2x variants Apple expects inside an iconset.
    for base in (16, 32, 128, 256, 512):
        img.resize((base * 2, base * 2), Image.LANCZOS).save(
            os.path.join(OUT, f"icon_{base}x{base}@2x.png"))
    for stale in ("icon_64x64.png", "icon_1024x1024.png"):
        p = os.path.join(OUT, stale)
        if os.path.exists(p):
            os.remove(p)
    print("wrote", OUT)


if __name__ == "__main__":
    build()
