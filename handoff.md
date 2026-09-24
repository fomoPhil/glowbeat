# Glowbeat handoff

Last updated 2026-09-23 (session 01B3VyjvQPtLjJ8x4PSU7gWZ). Read this first in any new session.

## Repos (2026-09-24, read first)
- PUBLIC: https://github.com/fomoPhil/glowbeat, branch `main`. Starts at one clean commit
  "Glowbeat 1.0.0" (d4ca8d7). All new work goes on `main` here. Release v1.0.0 is published
  with Glowbeat-1.0.0.dmg, Glowbeat.dmg (stable name the website links to) and appcast.xml.
- PRIVATE ARCHIVE: https://github.com/fomoPhil/glowbeat-archive holds the full pre-1.0 history
  (branches build-v1, master), including research material that must never be made public
  (decompiled Govee code). Local remote name: `archive`. Full backup bundle:
  ~/Projects/glowbeat-full-history-2026-09-24.bundle.
- The .superpowers ledger and reports stay local (gitignored).

## What Glowbeat is
Native macOS app (SwiftUI, Swift 6) that controls Phil's six Govee H6004 Wi-Fi bulbs over the LAN and runs an audio-reactive Party Mode from a CoreAudio system-audio tap, plus five non-music scenes. Name stays Glowbeat (name check: docs/research/name-check-glowbeat.md). Icon chosen: spectrum-bars bulb (docs/design/AppIcon-1024.png, wired into App/Assets.xcassets).

## Where things are
- Repo: ~/Projects/glowbeat, branch `build-v1` (55+ commits ahead of `master`, which only holds the initial docs). NOT merged yet.
- Specs: docs/superpowers/specs/ (v1 design, v1.1 addendum, v1.2 addendum A to Q). Plan: docs/superpowers/plans/2026-09-11-glowbeat.md.
- Decision ledger (every ruling, parked item, deferred minor): .superpowers/sdd/2026-09-11-glowbeat/progress.md (gitignored, on disk only). Reports for each task live next to it.
- Hardware test script: docs/manual-hardware-checklist.md.
- Research (protocol decompile, LAN probes, macOS audio): docs/research/.
- Built app Phil runs: build/DerivedData/Build/Products/Debug/Glowbeat.app. Other DerivedData-* folders are agent scratch builds.

## Build and test (headless, no Xcode GUI)
```
xcodegen generate
xcodebuild -project Glowbeat.xcodeproj -scheme Glowbeat -configuration Debug -derivedDataPath build/DerivedData build
swift test --package-path Packages/GoveeLAN -Xswiftc -warnings-as-errors   # also Effects, AudioTap
xcodebuild ... -destination 'platform=macOS' test    # app tests; while a live Glowbeat runs, override GLOWBEAT_INFOPLIST_FILE (see .superpowers/sdd/2026-09-11-glowbeat/v11-report.md) because LSMultipleInstancesProhibited blocks the test host
```
Zero warnings is enforced. Signing: Personal Team AXW4GKUTKZ, bundle id com.philwoolley.glowbeat.

## Releases (added 2026-09-24)
- Direct download build: `scripts/release.sh <version> <build>` makes a signed, notarized, stapled `dist/Glowbeat-<version>.dmg` and `dist/appcast.xml`. Full steps in docs/releasing.md.
- Sparkle 2 (SPM) auto-update: "Check for Updates..." in the app menu, automatic checks on, feed `https://github.com/fomoPhil/glowbeat/releases/latest/download/appcast.xml`. EdDSA private key in the login keychain under account `glowbeat`; public key is `SUPublicEDKey` in App/Info.plist. Not started under XCTest.
- "Support Glowbeat..." in the app menu and a quiet line at the bottom of Settings link to https://ko-fi.com/philwoolley (`Support.donationURL`). No pop-ups or reminders, ever.
- Any xcodebuild that resolves Sparkle needs `-packageAuthorizationProvider netrc`, or it hangs on an invisible keychain prompt.

## Hard-won facts (do not rediscover)
- H6004 ignores every realtime packet style (razer 0xBB and ptReal BLE relay). Party Mode is colorwc fades at up to 10/s. Do not retest.
- A stray Glowbeat process holding UDP 4002 silently steals bulb replies: `pgrep -fl MacOS/Glowbeat` and `lsof -nP -iUDP:4002` before blaming discovery. App is single-instance now.
- macOS Local Network permission must be allowed for the .app (System Settings > Privacy & Security > Local Network). Terminal probes are exempt, so "probe works, app does not" means this.
- The bulb string is on a scheduled smart switch; bulbs go offline at night.
- Phil's MacBook menu bar is full; macOS hides the status item there. It shows on the external monitor.
- GPT Image 2.5 with a reference image returns near-copies; use text-only prompts for variations.
- Always warn Phil before anything changes the bulbs (tell him what to watch, 10 s delay).
- The app test host is the real Glowbeat app. Under XCTest `GlowbeatApp` skips `startServices`, so an app test run binds nothing on UDP 4002 and never scans, polls or schedules the real room (`TestHostTests`). Before 2026-09-22 every run did.
- Nothing above the pane's scroller in the main window may have an unbounded height. The split view's column minimum is measured at zero width, so one `fixedSize` vertical text in the banner took the whole window apart (2026-09-22). `MainWindowLayoutTests` catches it; `snapshotLayout` cannot.

## State of the app (all built, tests green 2026-09-23: Effects 159, GoveeLAN 88, AudioTap 21, App 501; the 2026-09-23 network and brightness fixes are not reviewed yet)
- Discovery, per-bulb and All controls, names, drag-to-reorder, Identify flash, persistence.
- Party Mode: Pulse / Spread / Wave / Glow; one "Trigger Level" gate marker with an Always react checkbox; a Feel row (Punchy / Mellow / Dreamy / Tight / Custom) that ships on Punchy; a Bulbs row on Spread that puts each bulb on Bass, Mid or High; a Travel slider on Wave; Advanced disclosure with Darkest, Brightest, Snap, Fade and a
  Reset / Save as default row at the end of it; ten palettes; phone takeover pauses (power and brightness on the first poll, color after three polls that agree; a brightness Glowbeat just set is only judged once the bulb has shown it). A send budget of sixty colors a second for the whole room, and every bulb set to its own full brightness as Party Mode or a scene starts.
- Scenes: Breathe, Color flow, Candle, Sunset (progress bar, ends off), Static (Single color switch). Mutually exclusive with Party.
- Window: a sidebar of five panes (Bulbs, Party, Scenes, Colors, Schedule) with live status lines, and a persistent bulb strip along the bottom with identify on hover and drag to reorder. No slider anywhere draws tick marks.
- Colors: 26 curated still colors in four groups plus a brightness slider. One shot, not a driver: it stops everything else, paints once, and lets go. The same 26 are also a compact swatch grid in the menu bar popover.
- Schedule: Daylight / Night / Auto (Auto follows Night Shift, then the sun), wake and sleep timers with ramps, catch up after the Mac sleeps.
- Optional menu bar extra, Settings (gear in toolbar, General and Schedule tabs), first-run guide, launch at login (test seam so tests never touch the real login item).
- App icon and menu bar template icon.

## Earlier on 2026-09-14: Party Mode snappiness fix (commits f4caa60 + 0efa7ed)
Phil reported the lights taking seconds to react with the Trigger Level marker at 69%. Root cause,
proven by replaying real tracks offline through the exact pipeline (simulator brief and numbers
in .superpowers/sdd/2026-09-11-glowbeat/snappiness-brief.md and snappiness-report.md): Pulse,
Wave and Spread only move on a low band beat, and the marker drove the beat detector up to
2.5x the rolling mean; real mixes never clear ~1.65x, so the top half of the marker starved
the detector (hip hop mix: median 4 s between pulses, gaps to 43 s). Detector is now a straight
line 1.65x to 1.2x. Snap reads in seconds ("instant" at the top) with a caption saying higher
is faster. Not hardware verified yet; build/DerivedData holds the new build but Phil's running
copy (PID 43111 at the time) was NOT relaunched. Phil's stored partySnap is 0 (slowest); he
set it before the caption existed.
Not fixed, worth knowing: Glow with the marker high (69%) almost never lights, because its
brightness only starts above the marker. Bulb side latency (H6004 firmware fade, any command
queueing at 8 to 10 sends/s) was not measured; if the room still lags after this build, that is
the next thing to test with a timed colorwc + eyes.

## Also on 2026-09-14 (pm): Wave Travel, Fade 5 s, Trigger Level + Always react, design mockups
- Wave "Travel" slider 1 to 15 bulbs/s (f96dfe6), Fade ceiling 5 s (1193e70), "Reacts to" renamed
  "Trigger Level" (742af58), "Always react" checkbox that opens the gate and pins the detector to
  sensitivity 0.5 (a9263af). App tests 193, Effects 147. Phil's install relaunched on this build;
  his stored partyFade key was reset (log scale slider position would have drifted to 0.95 s).
- Five HTML mockups of the Party panel in docs/design/mockups (open index.html on port 50188):
  01 MiniDisc, 02 PW-SEQ-1, 03 hybrid, 04 the new Glowbeat Design System, 05 minimal 2026.
  Audits: AUDIT-feel-better.md (01 to 03) and AUDIT-glowbeat-system.md (04, 26 fixes applied).
- New design system at ~/Projects/Design Systems/Glowbeat Design System (MiniDisc + SEQ-1 +
  Liquid Glass + SwiftUI, no dots rule). Phil picked 05 that evening; see the next section.

## Latest: Feel presets + the Party panel restyle (2026-09-14 evening, commits 10d6144, 16f82da, docs)
Phil picked mockup 05, so the Party Mode section now looks like it: one neutral surface,
one amber accent (asset color, both appearances), Trigger Level alone on a glass sheet
(real Liquid Glass on macOS 26, material on the 14.4 target) with a neutral 48 segment
meter and a marker with a grip, concentric radii, shadows instead of borders, sentence
case, monospaced digits, 40 point rows and a 0.96 press scale that Reduce Motion turns
off. Tokens: `App/Views/PartyStyle.swift`. Scenes, the bulb list and the menu bar popover
were deliberately left alone.

New **Feel** row above Advanced in both windows: Punchy, Mellow, Dreamy, Tight, plus a
Custom state that appears the moment a slider moves. A feel is only the four Advanced
values (table in spec section I); it never touches Trigger Level, Always react, Travel,
the effect or the palette. App tests 193 to 208, packages unchanged (Effects 147,
GoveeLAN 63, AudioTap 21). PNGs of the panel in both appearances and every feel are in
`build/snapshots/` (gitignored), rendered by `AppTests/PartySnapshotTests.swift`. Not
hardware verified: nothing was run against the bulbs, Party Mode was never started and
Phil's running Glowbeat (PID 56877) was not touched. Checklist Step 4b covers both.

## Latest: Punchy by default + per bulb bands for Spread (2026-09-14 evening, commits 7b2370f, d93029d, 3aa7770, docs)
Two things Phil asked for.

**Glowbeat now ships on Punchy.** `GlowbeatSettings.defaults` takes its four feel values
from `PartyPreset.punchy` rather than retyping them, so a fresh install reads Punchy on
the Feel row instead of Custom. `EffectTiming.standard` (0.05 s / 0.5 s) stays the Effects
package's own default for an effect built without the engine, and a test asserts the two
are now deliberately different. Stored values are untouched, so Phil's own sliders did not
move.

**Each bulb can be put on Bass, Mid or High in Spread.** A "Bulbs" section appears under
the effect picker when Spread is chosen, the way Travel appears for Wave, and is not in
Settings. One cell per bulb: its name over a Bass / Mid / High segmented control, two
columns in a normal window. A band is keyed on the bulb id, so it survives a reorder and a
relaunch; a bulb nobody has chosen for keeps the old round robin for its place in the
list. `SpreadGroup` and `SpreadEffect.setAssignment(_:)` live in the Effects package;
`spreadAssignments` in settings; `PartyEngine.setSpreadAssignments(_:)` applies it live.

Suites: Effects 147 to 159, GoveeLAN 63, AudioTap 21 (2 skipped), App 208 to 221, zero
warnings. New PNGs in `build/snapshots/`: `spread-bulbs-dark.png` and
`spread-bulbs-empty-dark.png`. Not hardware verified: nothing ran against the bulbs, Party
Mode was never started, and Phil's running Glowbeat (PID 70159) was not touched, so
`build/DerivedData` still holds the older build he is running. Checklist has a new Bulbs
sub-step under Step 4; v1.2 addendum has section K. Report: spread-bands-report.md.

## Latest: the Party panel's type pairing (2026-09-14, one commit)
Phil picked pairing 2 from `docs/design/mockups/fonts.html`, so the panel now draws in
three faces instead of one.

**Rounded for the mood, in two places only.** "Party Mode" at the top of the panel, and
the five names on the Feel row. They are the only words in the panel naming how the room
should feel; Effect, Palette and the Spread Bulbs rows name settings, so they stay in the
plain system face along with every label and caption.

**Monospaced for every number that moves.** The big Trigger Level percentage, and Darkest,
Brightest, Snap, Fade and Travel out at the right, in both the Party panel and Settings.
SF Mono is wider than SF Pro Text, so both readout columns grew (56 to 60 points, and
Travel's 74 to 84) and a test now measures every readout string in the face that prints
it, the way the label column on the other side of the bar already was.

Suites: Effects 159, GoveeLAN 63, AudioTap 21 (2 skipped), App 221 to 224, zero warnings.
All eleven PNGs in `build/snapshots/` re-rendered and checked for clipping in both
appearances. Not hardware verified: nothing ran against the bulbs, Party Mode was never
started, and Phil's running Glowbeat (PID 70159) was not touched, so `build/DerivedData`
still holds the older build he is running. Checklist Step 4b gained a "three faces"
bullet; v1.2 addendum has section L. Report: fonts-report.md.

## Latest: Reset + Save as default in Advanced (2026-09-14, commits 4ad5398 + the UI/docs commit)
Phil: "add a save as default button when the advanced tab is open. also include a reset
circle arrow icon to reset the advanced settings back to the initial advanced settings."

The end of Advanced now has two buttons: **Reset** (circular arrow) and an amber **Save as
default**. They touch only the four Advanced values (Darkest, Brightest, Snap, Fade), never
Trigger Level, Always react, Travel, the effect or the palette. Both are dimmed whenever
the four already are the default, which is what a fresh install shows. Saving flashes
"Saved" with a checkmark for 1.5 s. Reset goes back to the saved default, or to Punchy
before anything is saved, and says which in its tooltip. The same row is in Settings.

The default is stored under `savedAdvancedDefault` as four doubles and is nil until
someone saves, so nothing had to be migrated. Suites: Effects 159, GoveeLAN 63, AudioTap
21 (2 skipped), App 224 to 238, zero warnings. New PNG:
`build/snapshots/advanced-buttons-dark.png`. Not hardware verified: bulbs untouched, Party
Mode never run, Phil's running Glowbeat (PID 70159) not touched, so `build/DerivedData`
still holds the older build he is running. Checklist Step 4b has a new sub-step; v1.2
addendum has section M. Report: advanced-default-report.md.

## Latest: the sidebar layout, the bulb strip and the Schedule pane (2026-09-16, commits 0edd0e5, 2f1d5b3, ca8caae, docs)

Phil picked layout B from `docs/design/mockups/layouts.html`, so the window is no longer
one long scroller. It is a **sidebar of four panes** (Bulbs, Party, Scenes, Schedule),
each with a live line under its name saying what it is doing ("2 of 6 on", "On, Pulse,
Punchy", "Color flow", "Wake 6:30 AM, sleep 11:00 PM"), and the pane it was left on comes
back next launch. A **bulb strip** runs along the bottom of the window on every pane but
Bulbs: 150 point tiles with a name, a switch, a brightness slider and a color swatch that
opens a popover, plus a flash button on hover and a drag that reorders. The strip scrolls
sideways and never wraps; six tiles fit the window Glowbeat opens at.

**One naming rule, Phil's call the same day:** a bulb nobody has named is called by its
place in the list and renumbers the instant the order changes, in the list, the strip, the
Spread grid and Identify at once. A name someone typed stays with that bulb.

**The Schedule pane** (Pass B of the Schedule feature) is two cards: a Light card with
Daylight / Night / Auto, a live caption saying what it is following, and a "Shift over"
slider that appears only under Auto; and a Schedule card with the enable switch in its
header, wake and sleep times, both ramps, the wake brightness, a live "Next: wake 6:30 AM
tomorrow." line and the two notes about the Mac having to be awake and the bulbs having to
have power. Settings has tabs now, General and Schedule, and the Schedule tab is the same
two cards rather than a copy.

The Party panel lays out in **two columns** in the pane, which is what makes it fit at
all, and **Advanced ships open** now that there is room for it.

Suites: App 288 to 336, Effects 159, GoveeLAN 63, AudioTap 21 (2 skipped), zero warnings.
Five PNGs in `build/snapshots/`: `sidebar-bulbs.png`, `sidebar-party.png`,
`sidebar-scenes.png`, `sidebar-schedule.png`, `sidebar-party-light.png`. Read them knowing
`ImageRenderer` paints a red glyph over every `Slider`, `Toggle` and `List`.

**One thing needs Phil's ruling: the window opens at 1000 x 820, not the mockup's 760.**
Measured, the Party pane's content is 582 points with Advanced open and 760 leaves it 555.
The alternative is a scroller under Advanced. Report: `sidebar-report.md`.

Not hardware verified: nothing ran against the bulbs, Party Mode was never started, Night
Shift was never read or written, and Phil's running Glowbeat (PID 4631) was not touched,
so `build/DerivedData` still holds the older build he is running. Checklist has a new Step
0b (window layout) and Step 9 (Schedule); v1.2 addendum has sections N and O.

## Latest: no tick marks, and the Colors pane (2026-09-17, commits d96cd88, a1f1c58, df43c77, docs)

Two things Phil asked for.

**Every slider in the app is clean.** Phil: "there are little tick marks under some of the
sliders. remove all visual tick marks." They were never a design choice: on macOS a
`Slider(value:in:step:)` is drawn by an `NSSlider` with one tick mark per step, and there
is no way to ask AppKit for the stepping without the marks. Six sliders had a step (Travel,
the three Schedule sliders, Shift over, and Party Mode updates per second in Settings).
They are all continuous now and the rounding happens in the binding, so Travel still lands
on whole bulbs and the ramps on whole minutes. Two tests hold the rule: one walks the real
AppKit view tree behind every pane, Settings and the popover and asserts no slider has a
mark, the other scans the app's own source for a `step:`.

**A fifth sidebar pane, Colors.** Phil: "individual static colors and a brightness slider
so you can easily pick a color, choose the brightness, and move on with life." It sits
between Scenes and Schedule and holds 26 curated colors in four groups (Whites by Kelvin
from Candle 2700 to Overcast 6500, then Sky, Mood and Playful), with a Brightness slider
above the grid. A click applies at once: it stops Party Mode, any scene and any ramp, then
sends on, the color, the brightness. Then nothing. That is the whole point: a still color
is not something that runs, so the room holds it until somebody, or the next Light
transition, changes it, and the pane has no switch and no Apply button.

The sidebar line reads "Golden hour, 70%" while a color is on the room and "Off"
otherwise. The pick is remembered across a relaunch and the applied state is not, because
a one shot leaves the app no way to know what the bulbs are still wearing.

Suites: App 336 to 405, Effects 159, GoveeLAN 63, AudioTap 21 (2 skipped), zero warnings.
Two PNGs in `build/snapshots/`: `sidebar-colors.png` and `sidebar-colors-light.png`, at
the size the window opens at, and three more recording the states the tick marks used to
be in (those three show yellow rectangles where the sliders are, which is `ImageRenderer`,
not the app). Checklist has a new Step 10; v1.2 addendum has sections P and Q. Report:
`colors-report.md`.

**One thing needs Phil's ruling: the Colors pane scrolls by about 167 points**, a little
under two rows of swatches, at the window Glowbeat opens at. The brightness slider is above
the grid so that costs nothing. A smaller swatch would close most of it.

Not hardware verified: nothing ran against the bulbs, Party Mode was never started, and
Phil's running Glowbeat (PID 56214) was not touched, so `build/DerivedData` still holds the
older build he is running. **The 26 color values are the one part of this that only the
room can prove.**

## Latest: the Colors grid in the menu bar popover (2026-09-17 pm, one commit)

Phil: "add the color selection to the toolbar. Maybe just have colors and then a simple
swatch color picker thing that has the different colors that you have here in the app."
The toolbar he means is the menu bar extra's popover.

**A Colors block, between All bulbs and Party Mode.** A header with the applied color
named on its right, then four rows of small swatches, one row per catalog group, so the
whites cluster at the top exactly the way they do in the pane. It is the *same* 26 colors:
the grid reads `StillColor.colors(in:)` and a click calls `AppModel.applyStillColor`, so
there is one catalog and one apply path in the app, and a test scans the menu bar source
for a second list in case anyone is tempted. Names have nowhere to go at 26 by 18 points,
so they live in the tooltip (a white also gives its temperature, "Warm, 3000 K") and in
the accessibility label. The chosen swatch takes a 2 point amber ring and pulls in to 0.9
inside it, which is what keeps the ring visible on the six amber colors in the catalog.
The popover widened from 280 to 320, which is what Mood's nine swatches need.

**The brightness slider now has two jobs, because there were always two brightnesses.**
`setBrightness` is a raw command to every bulb that remembers nothing; `setStillBrightness`
is the Colors pane's persisted setting, the one a still color is sent at. They were never
the same store. The popover's slider now follows the room: with a color applied it is that
color's brightness (and the Colors pane's slider moves with it, and it survives a
relaunch), with nothing applied it is the plain All bulbs command it has always been. No
tick marks, here or anywhere.

Suites: App 405 to 432, Effects 159, GoveeLAN 63, AudioTap 21 (2 skipped), zero warnings,
built only into `build/DerivedData-menubar`. Two PNGs in `build/snapshots/`:
`menubar-colors.png` and `menubar-colors-light.png` (the yellow rectangles in them are
`ImageRenderer` refusing to draw AppKit controls; the swatch grid is real). Checklist Step
10 has two new sub-steps; v1.2 addendum section Q has two new bullets. Report:
`menubar-colors-report.md`.

**One thing needs Phil's ruling: clicking a swatch snaps the popover's brightness slider
to the Colors brightness** (70% on a fresh install), because that is what the color was
just sent at. If he would rather his current slider position be the brightness the color
lands at, say so and it changes.

Not hardware verified: nothing ran against the bulbs, Party Mode was never started, and
Phil's running Glowbeat (PID 57918) was not touched, so `build/DerivedData` still holds
the build he is running.

## Latest: the window coming apart when the music goes quiet (2026-09-22, commit e8c21b2, docs)

Phil: "if the lights fade to zero, then you get that UI bug but when music starts playing
again, then the whole UI shows properly." The sidebar went blank, the pane header, the
strip and the footer vanished, and the Party pane started half way down.

**Cause, measured, not guessed.** Three seconds of silence is `.deniedOrSilent`, which
raises the red audio banner above the pane. Its explanation was `fixedSize` vertically,
and the detail column's minimum height is measured with no room at all, so that text
wrapped one character per line and asked for 1504 points. The split view honored it:
1603 points tall in a 700 point window, laid out from -478.5 to 1124.5, which pushed the
top of the window out the top and the strip and footer out the bottom. Every banner did
it (no bulbs, paused, network), not just the audio one.

**Fix.** The banner's text is bounded (three lines, whole message in a tooltip; every
message fits in two or three at any real window size), and the detail column no longer
reports a minimum height at all, so nothing a pane shows can take the window apart again.
A new suite, `AppTests/MainWindowLayoutTests.swift`, hosts the real window in a real
`NSWindow` and checks every banner on every pane at 1000 x 700 and at the minimum.

Suites: App 432 to 438, Effects 159, GoveeLAN 63, AudioTap 21 (2 skipped), zero
warnings, built only into `build/DerivedData-layoutbug`. Checklist Step 7 has a new
sub-step. Report: `silence-layout-bug-report.md`. Not seen by Phil yet: the suite's
windows are never on screen, nothing ran against the bulbs, and Phil's running Glowbeat
(PID 36644) was not touched, so `build/DerivedData` still holds the build he is running.

## Latest: a pause in the music is not an error, and the test host keeps off the network (2026-09-22, commits 662bdff, 56a758f, docs)

**The red audio banner is for real trouble now.** Phil's ruling on the banner that came up
every time a song ended. A Party session that has never heard anything and goes quiet
still gets the red "Glowbeat is not hearing any audio" banner, copy unchanged, because
that is what a missing permission looks like; so does a tap that will not open. A session
that has heard music and then goes quiet shows no banner, and the status line reads
"6 bulbs. Waiting for music." (the menu bar popover's top line too). `AppModel` tracks
`hasHeardAudioThisSession`: reset when Party Mode starts, set by the first sign of audio
while it runs or is still switching on, kept through a pause and Resume, cleared when it
stops. The engine and the tap are untouched. One accepted cost: a permission revoked in
the middle of a session that already heard music reads "Waiting for music" until Party
Mode is switched off and on.

**App test runs no longer touch the real room.** The app test host is the real app, and
until today every test run bound UDP 4002 and scanned and polled the real bulbs from a
second process (and started the schedule and the light mode against the room). Under
XCTest the entry point now skips `startServices`. Verified with `lsof -nP -iUDP:4002`
sampled every half second through two full suite runs: only Phil's running Glowbeat ever
held the port.

Suites: App 438 to 448, Effects 159, GoveeLAN 63, AudioTap 21 (2 skipped), zero
warnings, built only into `build/DerivedData-banner`. Checklist Step 7's layout sub-step
now starts Party Mode in silence to raise the banner, and a new sub-step covers the
pause; v1.2 addendum has section R and a dated bullet under F. Report:
`silence-banner-report.md`. Not seen by Phil yet: nothing ran against the bulbs, Party
Mode was never started on hardware, and Phil's running Glowbeat (PID 36644) was not
touched, so `build/DerivedData` still holds the build he is running.

## Merged 2026-09-23: budget + full brightness + feel + Confetti on build-v1
Both 2026-09-23 branches are merged (feat/feel-confetti into build-v1 on top of c18081d..fd832c4).
Combined suites: App 520 (6 skipped), Effects 209, GoveeLAN 88, AudioTap 21 (2 skipped), zero
warnings. New files needed `xcodegen generate` (GateGlide.swift, ConfettiToggle.swift). Window opens
at 1000 x 850 (Confetti row). Phil has not yet run this build on the bulbs.

## Latest: the room's send budget, real full brightness, one ordered stop (2026-09-23, commits c18081d, f522c4b, 172c892, docs)

Three fixes from the smoothness investigation and Phil's "the bulbs rarely reach actual
100% very much". Brief `network-brightness-brief.md`, report
`network-brightness-report.md`, v1.2 addendum section T, checklist Step 4d.

**The room shares sixty colors a second.** Ten bulbs at ten a second was a hundred
datagrams a second in bursts of ten, the likely cause of the jerky, late feel. Each bulb
now streams at `min(ceiling, max(2, 60 / bulbs))`: six bulbs 10/s, ten 6/s, fifteen 4/s,
worked out again live when a bulb joins or leaves. Inside a tick each bulb goes at its own
slot, about 20 ms across the room, instead of one burst. Party status polls stretch past
six bulbs so the room is asked six times a second (1.7 s at ten), which makes a phone
color take 3.3 to 5 s to catch at ten bulbs. The Settings slider is now "Most updates per
bulb, per second", a ceiling, reading "10 (6 with 10 bulbs)" when the room lowers it.

**Full brightness means full.** Party Mode dims in the colors it sends, which assumes the
bulb's own brightness is 100, but the Colors pane and the brightness sliders set that
brightness. Party start, Resume, a bulb joining mid session, and every scene now send
`setBrightness(100)` first. Stop leaves it there (nothing trustworthy to put back). The
takeover check only judges a brightness Glowbeat sent once the bulb has shown it, so a
bulb a repeat behind does not pause.

**The stop lands on the right thing.** Stopping on Auto used to end on the dim purple
settle color because it raced the Auto white on a second command chain. Now the light
mode wins when it has a white waiting, otherwise the dim base, and a still color picked
mid session is what the room ends on. One `switchPartyModeOff(settles:)` path; whatever
comes next waits for Party Mode's last command.

Suites: GoveeLAN 77 to 88, App 474 to 501 (6 skipped), Effects 159, AudioTap 21 (2
skipped), zero warnings, built only into `build/DerivedData-budget`. Not seen by Phil:
nothing ran against the bulbs, Party Mode was never started on hardware, and Phil's
running Glowbeat (PID 49269) was not touched, so `build/DerivedData` still holds the build
he is running. A parallel branch (`feat/feel-confetti`) owns the feel changes and has not
been merged with this.

## Latest: the feel, Spread bass at full, and Confetti (2026-09-23, branch feat/feel-confetti)

Phil's calls after the smoothness investigation found the room hopping color at constant
brightness rather than pulsing. Four changes, one commit each.

**The beat moves the brightness, the phrase moves the color.** Pulse, Spread and Wave
share a color clock: the palette moves on every four low beats, never sooner than 0.8 s
after the last change, and crossfades over 0.4 s. Every beat is still a full hit. Wave's
first bulb follows the fade and the new color travels in as a band. On the dance track at
Phil's settings the room changes color 0.96 times a second instead of 3.88, and no tick
moves the hue more than 13.8 delta E (was 30.2).

**The gate glides.** Below Trigger Level the room falls to Darkest over the Fade instead
of in one tick: a ceiling from the room's brightest bulb, falling at the Fade's rate, with
the effect still running underneath so Wave's highlight keeps traveling. Gate close drop
48 points to 10 on Pulse, Spread and Wave.

**Spread's bass bulbs reach full brightness**, told apart by a deeper shade of the palette
color (the nearest darker palette color in hue) instead of by 60 percent intensity. Bass
bulb peak 80.7 to 100 percent.

**Confetti**, a switch under the palette in the Party pane and in the popover: every bulb
its own palette color, never the same as its neighbors in the bulb order, re-scattered at
each color change, never crossing a neighbor even mid fade. Works with every effect, live,
remembered. Snapshots `build/snapshots/party-confetti-dark.png` and `-light.png` (drawn
through a real window, so the switch is real; it reads gray because the offscreen window
is never key).

**The window opens at 1000 x 850** (was 820): the Confetti row made the palette column 66
points taller, and the Party pane is measured to fit without a scroller, as before.

Suites: Effects 159 to 209, App 474 to 493 (6 skipped), GoveeLAN 77, AudioTap 21 (2
skipped), zero warnings, built only into the worktree's `build/DerivedData-feel`. Before
and after simulator tables: v1.2 addendum section U and `feel-confetti-report.md`.
Checklist: Step 4 bullets, Step 4a, and a Confetti sub-step. Not hardware verified: the
bulbs were never touched, Party Mode never ran against them, and Phil's running Glowbeat
was not touched.

## Open items
0aaaa. **Ruling wanted: the popover's brightness slider jumping to 70% when a swatch is
   clicked.** Keep it (the number is what the color was sent at) or make the slider's
   current position the brightness the color lands at. See `menubar-colors-report.md`.
0aaa. **Ruling wanted: the Colors pane's 167 points of scroll.** Keep the 96 x 56 swatch
   and four labeled groups as the brief specifies, or drop to 96 x 48 with tighter group
   spacing and buy back about 90 of it. See `colors-report.md`.
0aa. **Decide the window height**: 1000 x 850 as it ships now (820 until Confetti added a
   row under the palette on 2026-09-23), or back to 760 with a scroller under the Party
   pane. See `sidebar-report.md` and `feel-confetti-report.md`.
0ab. Phil's eyes on the sidebar, the strip and the Schedule pane (checklist Steps 0b and
   9). Decide whether the Scenes pane and the bulb list get the 05 treatment too, and send
   the menu bar popover screenshot for its own pass.
0. Phil's eyes on the restyled panel, the four feels and the new Bulbs row (checklist
   Step 4b and the Bulbs sub-step under Step 4). Decide whether the Scenes panel and the
   bulb list get the same treatment. **Glowbeat ships on Punchy is decided and done.**
0b. Phil replays the dense track that felt slow, marker high, and reports.
1. Phil's hardware pass on v1.2: default Party feel, Snap/Fade, each scene, menu bar toggle (no beach ball), phone takeover, and Step 4d (ten bulbs keep up, full brightness, the stop).
2. On "merge": merge build-v1 into master (git merge, then delete the SDD workspace per the ledger ruling).
3. Release polish (spec section H): About window, README with screenshots + GIF, real Govee Home screenshots in first-run, CHANGELOG + 1.0.0, MIT LICENSE, privacy note, window frame restore, Cmd+P shortcut, light/dark pass, Sparkle auto-update, notarized .dmg (Task 23 in the plan).
4. Deferred minors worth a v1.3 pass: `AppModelTests.testTheShippingFlashTakesAboutASecondAndAHalf` is a pre-existing wall clock flake (asserts 1.3 to 2.0 s elapsed, trips under full suite load, passes alone) and wants an injected clock; extract shared stream plumbing from SceneEngine/PartyEngine; "release" is a time constant for Glow/gate but a linear duration for beat effects; checklist says "0.2 s" where the Fade floor prints "0.1 s"; two bulbs named "Bulb 1" (Phil to confirm whether he named them).
5. Not started: Bluetooth transport, custom palettes, other Govee models (LAN protocol is generic, only H6004 tested).

## Process that worked
Fable orchestrates and reviews; Opus implements; every task gets an independent review and a fix round before it is called done. Reviews caught ~25 real bugs. Keep it.
