# Glowbeat app icon

The icon is a dark graphite macOS tile holding a glowing rainbow bulb: five vertical
bars in the shape of a bulb, over two purple bars for the base. Phil picked it from the
four AI concepts in `icons-ai/` (`concept-3.png`).

## Files

| Path | What it is |
| --- | --- |
| `icons-ai/concept-3.png` | The chosen concept art, as generated. Tile on a flat gray plate. |
| `AppIcon-1024.png` | The master: 1024x1024 RGBA, Apple squircle, transparent outside the tile. |
| `appicon-check.png` | Contact sheet, on white and on black at 512 / 128 / 64 / 32. |
| `tools/make_appicon.py` | Concept art to master. |
| `tools/make_assets.py` | Master to `App/Assets.xcassets`. |
| `../../App/Assets.xcassets/AppIcon.appiconset` | The 10 macOS slices Xcode compiles. |
| `../../App/Assets.xcassets/MenuBarIcon.imageset` | The 18 pt monochrome menu bar mark. |

Rebuild everything with:

```
python3 docs/design/tools/make_appicon.py
python3 docs/design/tools/make_assets.py
```

Both scripts are deterministic, so rerunning them on the same concept art reproduces
the same bytes. They need `pillow`, `numpy` and `scipy`.

## Why the tile gets rebuilt rather than cropped

The concept art draws its own tile with a plain circular corner, radius about 26.9% of
the side. That is not the macOS icon shape, and it is wrong in both directions: at the
very corner it is squarer than Apple's, and through the middle of the arc it is rounder.
Cropping alone would show slivers of the concept art's gray backdrop at each corner.

The real shape was measured off a shipping Apple icon (Keynote's `icon_128x128@2x`,
alpha channel). Body is 824 of 1024, and the corner is a superellipse over a corner box
of 0.2752 of the side with exponent 2.56, which fits Apple's alpha to about 0.18 px RMS.
So `make_appicon.py`:

1. crops the tile out of the concept art and squares it (the generated tile is 613x644,
   not square, so it is squashed about 5% vertically),
2. edge-extends the tile interior outward past its own rim, then blends that band toward
   a blurred copy so the extension does not streak,
3. cuts the real Apple shape,
4. redraws the glossy rim highlight along that edge, brighter at the top like the
   original, since the recut corners lost theirs,
5. adds the template drop shadow (12 px down, 26 px blur, black at 30%).

## Menu bar icon

`MenuBarIcon` is a template image: black on transparent, so macOS tints it for light and
dark menu bars automatically. Scaling the artwork straight down closes the gaps between
the bars into mush at 18 px, so the mark is redrawn on an 18 pt grid with whole-point
bars and 1 pt gaps. `GlowbeatApp.swift` passes it to `MenuBarExtra` as `image:`.

## Wiring

- `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`. The catalog itself
  needs no entry, because the app target's `sources` already globs all of `App/`.
- `App/Info.plist` is hand-written, so it carries `CFBundleIconName` explicitly.

Verify a build with:

```
python3 - <<'PY'
import struct
p = 'build/DerivedData-icon/Build/Products/Debug/Glowbeat.app/Contents/Resources/AppIcon.icns'
d = open(p, 'rb').read()
off, total = 8, struct.unpack('>I', d[4:8])[0]
while off < total:
    t = d[off:off+4].decode(); n = struct.unpack('>I', d[off+4:off+8])[0]
    print(t, n); off += n
PY
xcrun --sdk macosx assetutil --info <that app>/Contents/Resources/Assets.car
```

Like Apple's own apps, the emitted `.icns` carries only the four legacy sizes
(`ic04`, `ic11`, `ic07`, `ic13`). The full 16 to 1024 set lives in `Assets.car`, which is
what macOS actually reads.
