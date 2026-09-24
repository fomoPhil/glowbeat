# Glowbeat Party Mode: "make it feel better" audit

Audited 2026-09-14 against the `make-interfaces-feel-better` review checklist and its four
reference files (typography, surfaces, animations, performance). Code read directly from the
three mockups; each one also rendered in headless Chrome at 2x and inspected by eye for optical
alignment, radii, hit areas and hierarchy.

**Bottom line:** `03-hybrid.html` is closest to shippable. All three fail the same four checklist
items in the same way, which is good news: they are system fixes, not per-mockup fixes.

Legend: **P** pass, **F** fail, **n.a.** not applicable to a static HTML mockup.

---

## 1. `01-minidisc.html`

### (a) Checklist

| Item | | Selector or element at fault |
| --- | --- | --- |
| Concentric border radius | **F** | `.chip{border-radius:var(--r-sm)/*3px*/;padding:5px}` wraps `.chip .bar{border-radius:6px}`. Inner radius is larger than outer: inverted. Also `.tabs{border-radius:var(--r-md)/*5px*/;padding:3px}` over `.tab{border-radius:3px}` needs 6px. |
| Optical alignment | **F** | `.pal{display:flex;flex-wrap:wrap}` + `.chip{width:86px}` leaves a ~25px ragged right gutter; the palette does not line up with `.tabs` or `.vu` above and below it. (`.wintitle{margin-right:46px}` and `.on-air{padding:3px 8px 2px}` are correct optical work.) |
| Shadows over borders | **P** | `--shadow-chassis`, `--shadow-button`, `--shadow-lcd` are properly layered. Minor: `.chip{border:1px solid rgba(255,255,255,.07)}` is a depth border on a card, should be a shadow ring. |
| Enter animations split and staggered | n.a. | Static mockup, no enter sequence. Flagged for the real panel. |
| Exit animations subtle | n.a. | No exits. |
| Tabular numbers | **F** | `.lcd-readout` declares none. It survives only because VT323 is monospace and `min-width:74px;text-align:right` pins the box. Passing by accident, not by rule. |
| Font smoothing | **P** | `html,body{-webkit-font-smoothing:antialiased}` at root; `.lcd{-webkit-font-smoothing:none}` correctly opts the phosphor out. |
| `text-wrap: balance` / `pretty` | **F** | Absent everywhere. `.cap` under Trigger Level orphans "loud parts." onto line 2; `.note` and `.summary` same risk. |
| Image outlines | n.a. | No `<img>` elements. |
| Scale on press | **F** | Zero `:active` rules in the file. `.tab`, `.chip`, `.md-switch`, `.marker .grip` all give no press feedback. |
| `AnimatePresence initial={false}` | n.a. | No React or Motion. |
| No `transition: all` | **P** | Only `.disc .arrow{transition:transform .12s}`. |
| `will-change` scoped | **P** | Not used. Note: `@keyframes bounce` animates `width` on `.vu-veil`, which cannot be GPU-composited. |
| Minimum 40x40 hit area | **F** | `.marker .grip{width:15px;height:11px}` is the worst offender and it is the primary control. Also `.md-switch .track{height:22px}`, `.slider` (~18px), `.tab` (~34px), `.chip` (~35px), `.disc summary{padding:2px 0}`. |

### (b) Three highest leverage fixes

1. **Make the threshold marker the primary control, and make it hittable.**
   ```css
   .marker .grip{position:relative;width:18px;height:13px;
     background:linear-gradient(180deg,#8dffab 0%,var(--lcd-green) 100%);border:1px solid #14612c}
   .marker .grip::before{content:'';position:absolute;top:50%;left:50%;
     transform:translate(-50%,-50%);width:40px;height:40px}
   .marker .stem{background:var(--lcd-green);box-shadow:0 0 6px var(--lcd-green-glow)}
   ```
   Silver is chassis hardware in this system. The one thing the user drags must carry the accent.

2. **Grid the palette so its edges match every neighboring block.**
   ```css
   .pal{display:grid;grid-template-columns:repeat(5,1fr);gap:7px}
   .chip{width:auto}  /* delete the fixed 86px */
   ```

3. **Fix the inverted chip radius and the tab tray.**
   ```css
   .chip{border-radius:var(--r-md)/*5px*/;padding:3px 3px 4px}
   .chip .bar{border-radius:var(--r-xs)/*2px*/}   /* 5 = 2 + 3 */
   .tabs{border-radius:6px}                        /* 6 = 3 + 3 */
   ```

### (c) Hierarchy at a glance

No: the eye lands on the green power toggle, then on the solid green VU bar, while the actual
Trigger Level control is a 15x11 silver grip hanging below the meter in the only color on the
panel that is not the accent, so it reads as chassis trim rather than the thing you drag.

---

## 2. `02-pwseq1.html`

### (a) Checklist

| Item | | Selector or element at fault |
| --- | --- | --- |
| Concentric border radius | **F** | `.sw{border-radius:4px;padding:6px}` over `.sw .bar{border-radius:2px}`. Outer should be 8px. |
| Optical alignment | **F** | `.thumb{left:100%;margin-left:-9px}` on the Brightest row puts half the 18px thumb past the end of the track, with no end inset; visible in render. `.step{height:58px}` with `::after{top:8px}` and `padding-bottom:8px` leaves ~30px of dead center, so the active LED never visually binds to its label. |
| Shadows over borders | **P** | `--shadow-pillow`, `--shadow-tray`, `--shadow-cabinet` are layered correctly. |
| Enter animations split and staggered | n.a. | Static mockup. |
| Exit animations subtle | n.a. | No exits. |
| Tabular numbers | **F** | `.ds-value{font-variant-numeric:tabular-nums}` is declared but never used in the body. The live numbers are `.lcd .v` (VT323), which declares nothing. |
| Font smoothing | **F** | Root is correct, but `.lcd .v` omits `-webkit-font-smoothing:none`, so the VT323 phosphor renders soft here and crisp in 01 and 03. Inconsistent across the set. |
| `text-wrap: balance` / `pretty` | **F** | Absent. Same "loud parts." orphan under Trigger Level. |
| Scale on press | **F** | Zero `:active` rules. `--surface-hover` and `--surface-step-hover` are defined and no `:hover` rule consumes them. |
| `AnimatePresence initial={false}` | n.a. | No React or Motion. |
| No `transition: all` | **P** | Only `.pw-toggle::after{transition:transform var(--dur-quick) var(--ease-out)}`. |
| `will-change` scoped | **P** | Not used. `@keyframes lvl` animates `width` on `.lvl`, not compositable. |
| Minimum 40x40 hit area | **F** | `.mk .grip{width:16px;height:12px}`, `.pw-toggle{44x26}`, `.sl{height:28px}`, `.sw` (~39px). `.step{height:58px}` passes. |

### (b) Three highest leverage fixes

1. **Separate the marker from the peak.** They sit 5% apart in near-identical orange and amber
   and are indistinguishable in the render. Give the peak no fill weight and the marker all of it.
   ```css
   .pk{width:1px;background:transparent;border-left:1px dashed rgba(255,255,255,.55);box-shadow:none}
   .mk .stem{width:3px;background:var(--accent-orange);box-shadow:var(--glow-orange)}
   .mk .grip{position:relative;width:18px;height:14px}
   .mk .grip::before{content:'';position:absolute;top:50%;left:50%;
     transform:translate(-50%,-50%);width:40px;height:40px}
   ```

2. **Inset the slider thumb so 0% and 100% land inside the track.**
   ```css
   .sl{--thumb:18px}
   .thumb{margin-left:0;width:var(--thumb);
     left:calc(var(--p) * (100% - var(--thumb)) / 100)}
   /* markup: style="--p:64" instead of style="left:64%" */
   ```

3. **Close the dead space in the step buttons and fix the swatch radius.**
   ```css
   .step{height:46px;padding-bottom:7px}
   .step::after{top:9px}
   .sw{border-radius:8px}   /* 8 = 2 + 6 */
   ```

### (c) Hierarchy at a glance

Partly: the orange grip is correctly the accent color and does read as draggable, but it sits
next to an almost identical amber peak line and the animated green level repeatedly covers it,
so the eye lands on the Effect row's orange LED and the glowing THRESH readout before it ever
finds the control.

---

## 3. `03-hybrid.html`

### (a) Checklist

| Item | | Selector or element at fault |
| --- | --- | --- |
| Concentric border radius | **F** | `.chip{border-radius:var(--r-sm)/*3px*/;padding:5px}` over `.chip .bar{border-radius:6px}`: inverted, same as 01. `.tray-in{border-radius:var(--r-md)/*5px*/;padding:4px}` over `.step{border-radius:3px}` needs 7px. |
| Optical alignment | **F** | `.thumb{left:100%;margin:-9px 0 0 -9px}` overhangs the track end on the Brightest row (confirmed in render). `.step::after{top:8px}` in a 52px box repeats 02's LED-to-label gap, less severely. Palette grid and title compensation are correct. |
| Shadows over borders | **P** | `--shadow-chassis`, `--shadow-pillow`, `--shadow-tray`, `--shadow-lcd` all layered. Minor: `.chip{border:1px solid rgba(255,255,255,.07)}`. |
| Interruptible animations | **F** | The file contains **zero** `transition` declarations. `.md-switch .knob{left:2px→20px}` and every `.step.active` / `.chip.on` swap snaps instantly. |
| Enter animations split and staggered | n.a. | Static mockup. |
| Exit animations subtle | n.a. | No exits. |
| Tabular numbers | **F** | Not declared anywhere. Saved only by VT323 plus inline `min-width` on each `.lcd`. |
| Font smoothing | **P** | Root antialiased; `.lcd .v{-webkit-font-smoothing:none;text-rendering:optimizeSpeed}` is the most correct phosphor treatment of the three. |
| `text-wrap: balance` / `pretty` | **F** | Absent. `.note` orphans the single word "Inter." onto its own line; the Trigger caption orphans "loud parts." |
| Image outlines | n.a. | No `<img>` elements. |
| Scale on press | **F** | Zero `:active` rules. `.dimmed{opacity:.42}` is defined and never used. |
| No `transition: all` | **P** | Vacuously: there are no transitions at all. |
| `will-change` scoped | **P** | Not used. `@keyframes bounce` animates `width` on `.veil`. |
| Minimum 40x40 hit area | **F** | `.mk .grip{15x11}`, `.md-switch .track{40x22}`, `.sl{height:24px}`, `.chip` (~35px), `.disc summary`. |

### (b) Three highest leverage fixes

1. **Make the disabled Trigger state honest.** Right now `.trig.off` dims `.pk`, `.mk` and
   `.vu-labels` to 40% grayscale but leaves `.vu` at full green, so a pure readout is the
   brightest thing in the section and its only control is the dimmest.
   ```css
   .trig.off{opacity:.38;filter:grayscale(1);pointer-events:none}
   /* delete: .trig.off .pk,.trig.off .mk,.trig.off .vu-labels{...} */
   ```

2. **Add the state layer the whole file is missing.**
   ```css
   .step,.chip{transition-property:background-color,border-color,color,box-shadow;
     transition-duration:150ms;transition-timing-function:cubic-bezier(.2,0,0,1)}
   .md-switch .knob{transition-property:left;transition-duration:150ms;
     transition-timing-function:cubic-bezier(.2,0,0,1)}
   .step:active,.chip:active{transition-duration:100ms;scale:.96}
   .step:hover,.chip:hover{background:#26262e}
   ```

3. **Fix the inverted chip radius, the step tray, and the thumb end inset.**
   ```css
   .chip{border-radius:var(--r-md)/*5px*/;padding:3px 3px 4px}
   .chip .bar{border-radius:var(--r-xs)/*2px*/}
   .tray-in{border-radius:7px}                    /* 7 = 3 + 4 */
   .sl{--thumb:18px}
   .thumb{margin:-9px 0 0 0;left:calc(var(--p) * (100% - var(--thumb)) / 100)}
   ```

### (c) Hierarchy at a glance

No, and this is the worst of the three: the `.trig.off` rule grays the marker, stem and scale to
40% while leaving the VU meter fully lit, so the section's only interactive element is the
dimmest pixel in it and a readout is the brightest.

---

## Cross-mockup

### Closest to shippable: `03-hybrid.html`

Its geometry is already right where the others are not. The palette is a real grid
(`repeat(5,1fr)`) so every block shares one right edge, unlike 01's ragged flex-wrap. It runs a
single accent, which resolves the hierarchy question the other two leave open: orange means "you
control this," green means "this is the signal." Its LCD treatment is the most correct of the
three (scanline veil plus `-webkit-font-smoothing:none`), and its type split (Space Mono for
chrome, sentence-case Inter for help text) is the only one that reads cleanly at 13px.

Its three real defects are each a single rule. The dishonest disabled state is one selector. The
missing motion layer is four declarations. The inverted chip radius is two lines. By contrast 01
needs a layout change plus a color decision, and 02 needs thumb math, a step-button rebuild and a
meter that can distinguish its marker from its peak.

Runner-up is 01, purely on the meter: discrete segments behind a sweeping veil communicate
"lit versus unlit" far better than 02's continuous gradient fill, where the level and the
threshold sit on top of each other.

### Shared details that belong in a Glowbeat design system

1. **A state layer, before anything else.** All three files contain zero `:hover`, zero
   `:active` and zero `:focus-visible` rules. 02 even defines `--surface-hover` and
   `--surface-step-hover` that nothing consumes. One shared set of press, hover and focus tokens.
2. **One `Marker` component.** All three hang a 15-16 x 11-12px grip below the meter with no
   extended hit area. Ship it once with `::before{width:40px;height:40px}` and the accent fill.
3. **Peak and marker must never share a hue family.** All three place a thin peak line within
   5% of the marker stem in a nearly identical color. Make the peak a hairline tick and the
   marker the only solid accent shape in the meter.
4. **One slider primitive with thumb inset.** All three use `left:X%` with `margin-left:-9px`
   and no end compensation, so 0% and 100% hang off the track. Bake
   `left:calc(var(--p) * (100% - var(--thumb)) / 100)` into the component.
5. **Concentric radius as a token rule, not a judgment call.** Two of three nest a 6px pill
   inside a 3px card. Publish the pairs (2/5, 3/7, 5/8) and never hand-pick a radius again.
6. **Typography defaults.** All three correctly set `-webkit-font-smoothing:antialiased` at the
   root; none set `text-wrap:pretty` on help copy or `font-variant-numeric:tabular-nums` on live
   readouts. Both are one line in a root reset, and tabular-nums stops being accidental the
   moment a non-monospace font touches a number.
7. **Animate `transform`, not `width`.** All three level meters (`.vu-veil`, `.lvl`, `.veil`)
   keyframe `width`, which cannot be GPU-composited and forces layout every frame on an
   always-running animation. Use `transform:scaleX()` with `transform-origin:right`.
8. **Semantics.** 02 and 03 build the effect picker and palette from `<div>`, so neither is
   keyboard reachable; 01 uses real `<button>` but with no `aria-pressed`. There are zero `aria-`
   attributes across all three files.
