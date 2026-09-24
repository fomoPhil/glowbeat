# Glowbeat Design System + `04-glowbeat.html`: feel-better audit and fixes

Audited 2026-09-14 against the `make-interfaces-feel-better` checklist (all four reference
files), the `frontend-design` guidance, the seven defects carried over from
`AUDIT-feel-better.md`, and the system's own no-dots rule.

Scope: `Design Systems/Glowbeat Design System/` (`colors_and_type.css`, `components.css`,
`COMPONENTS.md`, `README.md`, `preview/*.html`) and `04-glowbeat.html`. Before and after
rendered in headless Chrome at 2x and inspected as crops of the Trigger Level module, the step
buttons, the sliders, the palette chips and the disclosure. Geometry checked numerically in the
browser, not by eye alone.

**Bottom line:** the system started far ahead of mockups 01 to 03. Five of the seven inherited
defects were already fixed by the system. The two that survived are the two that matter most,
and both are now closed: the slider thumb hung off the track end at 100%, and the meter marker
had no hit area, no states, and no way to stay visible where it crosses lit segments in its own
color.

---

## 1. The seven inherited defects, checked against 04 and the system

| Inherited defect | Before | After | Selector |
|---|---|---|---|
| No hover / active / focus-visible states | **Pass** (7 hover, 8 active, 8 focus-visible), except the marker and the slider thumb | Fixed | `.gb-meter-marker`, `.gb-slider-thumb` |
| No transitions | **Pass**, all named properties | Unchanged | system-wide |
| Live numbers not tabular | **Partial**: readouts tabular, `.gb-micro` and `.gb-chrome-label` not | Fixed | `.gb-micro`, `.gb-chrome-label` |
| Marker grip far under 40x40 | **Fail**: 18x12 grip, no extension | Fixed, measured 40x40 | `.gb-meter-marker::before` |
| Inverted concentric radii | **Pass** on tray/segmented/meter/swatch; **fail** on glass and switch | Fixed | `.gb-glass`, `.gb-switch .gb-knob` |
| Slider thumb hangs off the track end | **Fail**: `left:100%` + `margin-left:-7px` put half the thumb past the track | Fixed, overhang measured 0.0px | `.gb-slider-thumb` |
| Trigger Level not the eye's landing point | **Partial**: the section is the hero, but the marker vanished into the lit level | Fixed | `.gb-meter-marker` |

## 2. Full checklist

| Item | Before | After | Selector / note |
|---|---|---|---|
| Concentric radius | Fail | Fixed | glass 16 over inner 8 at 16 padding; now 24 = 8 + 16. Switch knob r6 inset 3 in an r8 track; now inset 2, 8 = 6 + 2. Swatch r10 was off the ladder; now 8 = 4 + 4 |
| Optical alignment | Pass | Unchanged | badge `padding: 4px 9px 4px 7px`, chevron `translate: 0 -1px`, check mark `margin-top: -2px` were all already correct |
| Marker lands on the true value | Fail | Fixed | `left:69%` was 69% of the housing, not of the segment bed. Now inset by the 5px pad; measured 69.0% |
| Shadows over borders | Pass | Unchanged | `--gb-shadow-1/2/3`, `--gb-cap`, `--gb-well-shadow` all layered and transparent |
| No `transition: all` | Pass | Unchanged | zero occurrences in any file |
| Interruptible transitions | Partial | Fixed | marker had none; now transitions `box-shadow` and grip `scale`, never `left` (a transition on `left` would lag a drag) |
| `scale(0.96)` on press | Partial | Fixed | 7 sites before, marker grip added. Step buttons already correct |
| 40x40 hit areas | Fail | Fixed | 6 extension sites; marker added. No overlap: the meter the marker covers is `role="meter"`, not interactive |
| Tabular nums on live readouts | Partial | Fixed | `.gb-micro` carries "6 bulbs" and the scale ends; `.gb-chrome-label` carries readout captions |
| `-webkit-font-smoothing` on root | Pass | Unchanged | `html.gb, .gb` |
| `text-wrap: balance` / `pretty` | Pass | Unchanged | balance on `.gb-title` and `.gb-heading`, pretty on `.gb-body`, `.gb-caption`, `.srcline` |
| Image / chip outlines | Fail | Fixed | `.gb img` had one; `.gb-swatch-bar` did not, so Warm White and Ice had no edge |
| `will-change` only where needed | Pass (unused) | Improved | added `clip-path` to the one continuously animated element |
| No dots | Pass | Unchanged | zero `border-radius: 50%`, zero dotted rules, zero bullet glyphs, zero circular indicators. The radial gradients present are ambient background washes, not dot textures |
| Focus rings | Partial | Fixed | slider thumb and marker are both `role="slider" tabindex="0"` and had no focus ring |
| Enter / exit stagger | n.a. | n.a. | static mockup |

---

## 3. Edits applied, with the values chosen

### `colors_and_type.css`
1. Radius ladder extended: added `--gb-r-7: 24px`. Worked-pairs comment rewritten with the
   corrected swatch pair, the new switch pair and the new glass pair.
2. `.gb-chrome-label`: added `font-variant-numeric: tabular-nums`.
3. `.gb-micro`: added `font-variant-numeric: tabular-nums`.

### `components.css`
4. `.gb-glass`: `border-radius` `var(--gb-r-5)` (16) to `var(--gb-r-7)` (24). **24 = 8 + 16**,
   where 8 is the meter housing and readout well inside it and 16 is the card's padding.
5. `.gb-switch .gb-knob`: 20x20 at `top/left: 3px` to **22x22 at `top/left: 2px`**.
   **8 = 6 + 2.** Travel stays 18px, so `translate: 18px 0` is unchanged.
6. `.gb-swatch`: `border-radius: 10px` to `var(--gb-r-3)` (8). 10 was not on the ladder, which
   the system's own rule forbids.
7. `.gb-swatch-bar`: `border-radius` `var(--gb-r-2)` (6) to `var(--gb-r-1)` (4). **8 = 4 + 4.**
8. `.gb-swatch-bar`: added `outline: 1px solid rgba(255,255,255,0.10); outline-offset: -1px`,
   with `rgba(0,0,0,0.14)` in both light-mode blocks.
9. `.gb-slider`: new `--gb-p: 0` (bare number, 0 to 100) and `--gb-thumb-w: 14px`.
10. `.gb-slider-fill`: `width: calc(var(--gb-thumb-w) / 2 + var(--gb-p) / 100 * (100% - var(--gb-thumb-w)))`,
    so the fill stops under the thumb's middle at every value.
11. `.gb-slider-thumb`: `left: calc(var(--gb-p) / 100 * (100% - var(--gb-thumb-w)))` and
    `margin-left: 0`. The thumb travels inside the track instead of centering on the raw
    percent. Measured overhang at 100%: **7px before, 0.0px after.**
12. `.gb-slider-thumb:hover`: added a lift plus a `rgba(139,92,255,0.55)` accent halo.
13. `.gb-slider-thumb:focus-visible`: added `box-shadow: var(--gb-focus)`.
14. `.gb-meter-marker`: `left: calc(5px + var(--gb-mark) / 100 * (100% - 10px))`, inset by the
    housing padding. Measured position: **69.0% of the segment bed.**
15. `.gb-meter-marker`: stem 2px to **3px**, `background` `--gb-accent` to `--gb-accent-hi`
    (`#a98aff`), and a **1px black casing** (`0 0 0 1px rgba(0,0,0,0.78)`) in front of the glow.
    This is the fix for "Trigger Level is not the landing point": `--gb-signal-rest` is the same
    `#8b5cff` as the accent, so the stem was invisible wherever the level covered it.
16. `.gb-meter-marker::before`: new **40x40** hit area centered on the grip
    (`left: 50%; bottom: 3px; translate: -50% 50%`).
17. `.gb-meter-marker::after` (the grip): 18x12 to **20x14**, `bottom: -4px` to `-5px`.
18. `.gb-meter-marker`: added `:hover` (brighter grip, stronger bloom), `:active`
    (`scale: 0.96` on the grip), `:focus-visible`, and named transitions on `box-shadow` and
    `scale`. Position is deliberately not transitioned.
19. `.gb-disclosure > summary:hover`: added `background: var(--gb-accent-wash)`. The rule already
    declared `transition-property: background-color` with nothing to consume it.
20. `.gb-disclosure > summary`: `padding: 0 8px; margin: 0 -8px`, so the hover tint reads as a
    row while the accent bar stays aligned with every other section title.

### `04-glowbeat.html`
21. Five sliders converted to `style="--gb-p:64.3"` (and 24, 100, 62, 24) on `.gb-slider`, with
    the child `width:` and `left:` inline styles removed. Every displayed value is unchanged.
22. The meter marker converted to `style="--gb-mark:69"`.
23. Local block: `will-change: clip-path` on `.hero .gb-meter-lit`, the one element on the page
    under a continuous animation and the only property here the GPU can composite.

### `preview/*.html`
24. Two sliders and six markers converted to the new API, prose in `components-controls.html`
    and `components-meter.html` updated to the new numbers, and the concentric-radius demo plus
    the radius ladder in `surfaces-glass.html` corrected (chip pair now 8 = 4 + 4, glass pair
    24 = 8 + 16 added, 24 added to the ladder).
25. All six pages (five previews plus 04) had their inlined `<style>` block regenerated from the
    two source CSS files by a script, so no page can drift from the system. Verified in sync.

### `README.md` and `COMPONENTS.md`
26. Ladder updated to 4/6/8/12/16/20/24 in both files. Concentric table gained the switch and
    glass rows and corrected the palette row. Switch knob 20x20 to 22x22. Slider rules replaced
    with the thumb-inset math and the `--gb-p` API. Marker rules replaced with the casing,
    the `--gb-mark` inset math, the 20x14 grip and the 40x40 hit area. Palette rules gained the
    chip outline. Glass gained its concentric pair. Disclosure gained the row bleed.

---

## 4. Deliberately left

- **`--gb-signal-rest` still equals `--gb-accent` (`#8b5cff`).** Strictly, the accent means "you
  control this," and spending it on a readout weakens that. But the violet meter is the panel's
  identity and the brief is polish, not redesign. The marker's black casing solves the legibility
  problem without repainting the hero. Worth revisiting if the marker still gets lost on hardware.
- **`.gb-shell-body` padding 24 against children at radius 8, 12 and 16.** Not concentric, and
  correctly so: at 24px of padding the skill and the system both say the layers read as separate
  surfaces and each radius is chosen on its own.
- **`.gb-badge::before` stays a keyframe animation.** Keyframes are wrong for interactive state,
  but this is an ambient status indicator that is never interrupted, which is exactly the case
  keyframes are for.
- **The `-12 dB` scale label sits at the flex center, not at the true -12 dB position.** Fixing it
  means changing what the panel says, and 04's content is frozen by instruction.
- **No enter or exit stagger added.** 04 is a static mockup, and `frontend-design` calls for one
  orchestrated moment rather than scattered entrances. The level meter is already that moment.
- **All of 04's labels, values and captions are byte-identical to before.** Only the mechanism
  that positions the thumbs and the marker changed.

---

## 5. Verification

Measured in the browser after the fixes, not estimated:

```
marker hit ::before          40px x 40px
marker center                69.0% of the segment bed   (target 69.0)
slider p=100 thumb overhang  0.0px                      (was +7px)
all 5 thumbs inside track    left true, right true
all 5 thumb hit areas        40px x 40px
```

`http://localhost:50188/04-glowbeat.html` serves the fixed page.
