#!/usr/bin/env python3
"""Build the Glowbeat macOS app icon master from the chosen AI concept art.

Input  : docs/design/icons-ai/concept-3.png  (1024x1024, tile on a flat gray plate)
Output : docs/design/AppIcon-1024.png        (1024x1024, Apple squircle + shadow, RGBA)
         docs/design/appicon-check.png       (contact sheet on white and black)

The concept art draws its own tile with a plain circular corner (r ~= 0.269 of the
side) which is not the macOS icon shape. The real shape was measured off a shipping
Apple icon (Keynote's 128x128@2x): body = 824/1024 of the canvas, corners are a
superellipse over a corner box of 0.2752 * side with exponent 2.56 (fits Apple's
alpha to ~0.18 px RMS). So the tile art is cropped, squared, edge-extended past both
mismatching corner shapes, cut with the real Apple mask, and given a fresh rim
highlight and the template drop shadow.
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / "docs/design/icons-ai/concept-3.png"
OUT = ROOT / "docs/design/AppIcon-1024.png"
SHEET = ROOT / "docs/design/appicon-check.png"

CANVAS = 1024
BODY = 824                      # Apple's macOS icon body inside a 1024 canvas
ORIGIN = (CANVAS - BODY) // 2   # 100

# Apple corner, measured from a shipping system icon.
CORNER_FRAC = 0.2752
CORNER_EXP = 2.56

# Tile bounding box measured in the concept art (first and last tile pixel).
TILE_BOX = (205, 188, 818, 832)  # left, top, right+1, bottom+1  -> 613 x 644
SRC_CORNER_R = 165.0             # circular corner radius of the concept tile
SAFE_ERODE = 8.0                 # px of the concept tile's own rim to discard

SS = 4                           # mask supersampling factor


def apple_mask(size: int, supersample: int = SS) -> np.ndarray:
    """Antialiased coverage mask of Apple's macOS icon shape, float 0..1."""
    n = size * supersample
    c = CORNER_FRAC * n
    ax = (np.arange(n) + 0.5)
    dx = np.minimum(ax, n - ax)          # distance from nearest vertical edge
    dy = dx.copy()                       # square, so the same profile both ways
    X, Y = np.meshgrid(dx, dy)
    inside = np.ones((n, n), dtype=bool)
    corner = (X < c) & (Y < c)
    u = np.clip((c - X[corner]) / c, 0.0, 1.0)
    v = np.clip((c - Y[corner]) / c, 0.0, 1.0)
    inside[corner] = (u ** CORNER_EXP + v ** CORNER_EXP) <= 1.0
    cov = inside.astype(np.float32).reshape(size, supersample, size, supersample)
    return cov.mean(axis=(1, 3))


def source_tile_mask(size: int) -> np.ndarray:
    """Conservative 'this is definitely concept tile' mask, eroded past its rim."""
    left, top, right, bottom = TILE_BOX
    sw, sh = right - left, bottom - top
    sx, sy = size / sw, size / sh          # the crop is not perfectly square
    rx, ry = SRC_CORNER_R * sx, SRC_CORNER_R * sy
    e = SAFE_ERODE
    ax = np.arange(size) + 0.5
    dx = np.minimum(ax, size - ax) - e
    X, Y = np.meshgrid(dx, dx)
    inside = (X >= 0) & (Y >= 0)
    corner = (X < rx - e) & (Y < ry - e)
    u = (rx - e - X[corner]) / max(rx - e, 1.0)
    v = (ry - e - Y[corner]) / max(ry - e, 1.0)
    inside[corner] &= (u * u + v * v) <= 1.0
    return inside


def build() -> Image.Image:
    src = Image.open(SRC).convert("RGB")
    tile = src.crop(TILE_BOX).resize((BODY, BODY), Image.LANCZOS)
    rgb = np.asarray(tile).astype(np.float32)

    # 1. Edge-extend the tile interior outward so neither corner mismatch can leak
    #    the concept art's flat gray backdrop (or a smeared copy of its own rim).
    safe = source_tile_mask(BODY)
    idx = ndimage.distance_transform_edt(~safe, return_distances=False,
                                         return_indices=True)
    rgb = rgb[idx[0], idx[1]]
    # Nearest-pixel extension alone leaves radial streaks in the corners, so the
    # extended band is blended toward a blurred copy of itself.
    smooth = np.dstack([ndimage.gaussian_filter(rgb[..., c], 6.0) for c in range(3)])
    inner = ndimage.distance_transform_edt(safe).astype(np.float32)
    w = np.clip(inner / 5.0, 0.0, 1.0)[..., None]
    rgb = w * rgb + (1.0 - w) * smooth

    # 2. Cut the real Apple shape.
    mask = apple_mask(BODY)

    # 3. Fresh rim highlight along that edge: the concept art's glossy rim, redrawn
    #    where the recut corners lost it. Brighter at the top, like the original.
    dist = ndimage.distance_transform_edt(mask > 0.5).astype(np.float32)
    rise = np.clip(dist / 1.8, 0.0, 1.0)
    fall = np.clip((6.5 - dist) / 4.7, 0.0, 1.0)
    rim = rise * fall * fall * (3.0 - 2.0 * fall)      # smooth peak just inside
    top_to_bottom = (np.arange(BODY, dtype=np.float32) / (BODY - 1))[:, None]
    strength = 0.200 - 0.055 * top_to_bottom
    rgb = np.clip(rgb + 255.0 * rim[..., None] * strength[..., None], 0, 255)

    body = np.dstack([rgb, mask * 255.0]).astype(np.uint8)
    body_im = Image.fromarray(body, "RGBA")

    # 4. Template drop shadow: y offset 12, blur 26, black at 30%.
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_a = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_a.paste(Image.fromarray((mask * 255 * 0.30).astype(np.uint8), "L"),
                   (ORIGIN, ORIGIN + 12))
    shadow_a = shadow_a.filter(ImageFilter.GaussianBlur(13.0))
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255))
    shadow.putalpha(shadow_a)
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(body_im, (ORIGIN, ORIGIN))
    return canvas


def contact_sheet(icon: Image.Image) -> Image.Image:
    sizes = [512, 128, 64, 32]
    pad, gap = 40, 40
    row_w = pad * 2 + sum(sizes) + gap * (len(sizes) - 1)
    row_h = max(sizes) + pad * 2
    sheet = Image.new("RGB", (row_w, row_h * 2), (255, 255, 255))
    sheet.paste(Image.new("RGB", (row_w, row_h), (0, 0, 0)), (0, row_h))
    for band, bg in enumerate(((255, 255, 255), (0, 0, 0))):
        x = pad
        for s in sizes:
            thumb = icon.resize((s, s), Image.LANCZOS)
            plate = Image.new("RGBA", (s, s), bg + (255,))
            plate.alpha_composite(thumb)
            y = band * row_h + pad + (max(sizes) - s) // 2
            sheet.paste(plate.convert("RGB"), (x, y))
            x += s + gap
    return sheet


if __name__ == "__main__":
    icon = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT)
    contact_sheet(icon).save(SHEET)
    print("wrote", OUT)
    print("wrote", SHEET)
