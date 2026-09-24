#!/usr/bin/env python3
"""Generate App/Assets.xcassets from the icon master.

  AppIcon.appiconset    10 macOS slices, Lanczos-downscaled from AppIcon-1024.png
  MenuBarIcon.imageset  18pt monochrome template mark (the bulb of bars, simplified)
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
MASTER = ROOT / "docs/design/AppIcon-1024.png"
CATALOG = ROOT / "App/Assets.xcassets"

INFO = {"author": "xcode", "version": 1}

# size (pt), scale -> filename
APPICON = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
           (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n")


def build_appicon() -> None:
    out = CATALOG / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    master = Image.open(MASTER).convert("RGBA")
    images = []
    for pt, scale in APPICON:
        px = pt * scale
        name = "icon_%dx%d%s.png" % (pt, pt, "@2x" if scale == 2 else "")
        img = master if px == master.width else master.resize((px, px), Image.LANCZOS)
        img.save(out / name)
        images.append({"filename": name, "idiom": "mac",
                       "scale": "%dx" % scale, "size": "%dx%d" % (pt, pt)})
    write_json(out / "Contents.json", {"images": images, "info": INFO})


# The menu bar mark is the icon's bulb-of-bars redrawn on an 18 pt grid: whole-pixel
# bars with 1 pt gaps, because scaling the artwork directly closes the gaps to mush at
# 18 px. Coordinates are in points on an 18x18 canvas.
MARK = [
    (2.0, 4.8, 4.0, 9.2),      # five vertical bars, short-tall-short bulb
    (5.0, 3.2, 7.0, 10.6),
    (8.0, 1.5, 10.0, 11.5),
    (11.0, 3.2, 13.0, 10.6),
    (14.0, 4.8, 16.0, 9.2),
    (5.0, 12.3, 13.0, 14.1),   # two base bars
    (5.9, 15.1, 12.1, 16.9),
]


def draw_mark(pt: int, scale: int, supersample: int = 8) -> Image.Image:
    px = pt * scale
    n = px * supersample
    k = n / 18.0
    img = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(img)
    for x0, y0, x1, y1 in MARK:
        a, b, c, e = x0 * k, y0 * k, x1 * k, y1 * k
        d.rounded_rectangle([a, b, c - 1, e - 1],
                            radius=min(c - a, e - b) / 2, fill=255)
    img = img.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.putalpha(img)
    return out


def build_menubar() -> None:
    out = CATALOG / "MenuBarIcon.imageset"
    out.mkdir(parents=True, exist_ok=True)
    images = []
    for scale in (1, 2):
        name = "menubaricon%s.png" % ("@2x" if scale == 2 else "")
        draw_mark(18, scale).save(out / name)
        images.append({"filename": name, "idiom": "universal",
                       "scale": "%dx" % scale})
    write_json(out / "Contents.json",
               {"images": images, "info": INFO,
                "properties": {"template-rendering-intent": "template"}})


if __name__ == "__main__":
    CATALOG.mkdir(parents=True, exist_ok=True)
    write_json(CATALOG / "Contents.json", {"info": INFO})
    build_appicon()
    build_menubar()
    print("wrote", CATALOG)
