#!/usr/bin/env python3
"""Draws the Glowbeat installer window background (dark, one soft spectrum glow).

Writes background.png (660x400) and background@2x.png (1320x800) next to this file,
then scripts/release.sh joins them into background.tiff for Retina. Run it again only
if the look changes; the outputs are committed.
"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
W, H = 660, 400
# The icon's colors, left to right.
SPECTRUM = [(255, 69, 48), (255, 159, 10), (52, 230, 120), (20, 190, 255), (60, 90, 255), (175, 82, 255)]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def spectrum_at(x):
    x = min(max(x, 0.0), 1.0) * (len(SPECTRUM) - 1)
    i = min(int(x), len(SPECTRUM) - 2)
    return lerp(SPECTRUM[i], SPECTRUM[i + 1], x - i)


def render(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), (24, 25, 30))
    # A gentle vertical falloff, charcoal to near black, like the icon's tile.
    grad = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        grad.line([(0, y), (w, y)], fill=lerp((34, 35, 42), (16, 16, 20), t))

    # The glow: a thin spectrum bar under the icons, blurred into light.
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    x0, x1 = int(150 * scale), int(510 * scale)
    y = int(292 * scale)
    for x in range(x0, x1):
        g.line([(x, y - 2 * scale), (x, y + 2 * scale)], fill=spectrum_at((x - x0) / (x1 - x0)))
    soft = np.asarray(glow.filter(ImageFilter.GaussianBlur(18 * scale)), dtype="float32")
    core = np.asarray(glow.filter(ImageFilter.GaussianBlur(1.2 * scale)), dtype="float32")
    base = np.asarray(img, dtype="float32")
    img = Image.fromarray(np.clip(base + soft * 0.55 + core * 0.5, 0, 255).astype("uint8"))

    d = ImageDraw.Draw(img)
    # A quiet chevron between the app and Applications.
    cx, cy = W // 2 * scale, 180 * scale
    s = 10 * scale
    d.line([(cx - s // 2, cy - s), (cx + s // 2, cy), (cx - s // 2, cy + s)],
           fill=(120, 122, 132), width=2 * scale, joint="curve")

    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 13 * scale)
    except OSError:
        font = ImageFont.load_default()
    text = "Drag Glowbeat into Applications"
    tw = d.textlength(text, font=font)
    d.text(((w - tw) / 2, 336 * scale), text, font=font, fill=(150, 152, 162))
    return img


render(1).save(HERE / "background.png")
render(2).save(HERE / "background@2x.png")
print("wrote", HERE / "background.png", HERE / "background@2x.png")
