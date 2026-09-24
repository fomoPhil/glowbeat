# Glowbeat on hardware checklist

This is the script for the one run that decides whether Glowbeat actually works. Every
item is judged by what Phil sees in the room, not by what the build says.

Fill in the header and the results table live, during the run. Do not pre-fill anything.

```
Run on:   <date>
Build:    Debug, <commit sha>
Bulbs:    6 x Govee H6004, firmware wifiVersionSoft 1.01.27
Mac:      macOS 26.6.2, MacBookPro18,4
Music:    <track used, so a rerun sounds the same>
```

## How to run this

Three rules, in order of how much damage breaking them does.

1. **Warn before every light change.** For any step marked WARN FIRST: tell Phil in one
   line what is about to happen and what to watch, wait for him to say "ready", then count
   down 10 seconds out loud, then run it. Bulbs jumping unannounced makes a working app
   look broken and a broken app look fine.
2. **Look at the lights.** UDP has no acknowledgment and Govee firmware acknowledges
   commands it ignores. A green build proves nothing about a bulb.
3. **A failure stops the run.** Write it in the Defects table, fix it with a failing test
   first, rebuild, and rerun only that item. One defect, one test, one commit.

If the first-run sheet appears at launch, dismiss it before timing anything. It is not
part of this checklist and it delays the moment the bulb list becomes visible.

---

## Step 0: Build a fresh signed app and confirm it is signed

No lights change. No warning needed.

```bash
cd ~/Projects/glowbeat
xcodebuild -project Glowbeat.xcodeproj -scheme Glowbeat -configuration Debug \
  -derivedDataPath build/DerivedData build
codesign -dv --verbose=2 build/DerivedData/Build/Products/Debug/Glowbeat.app 2>&1 \
  | grep -E "Authority|TeamIdentifier|flags"
plutil -p build/DerivedData/Build/Products/Debug/Glowbeat.app/Contents/Info.plist \
  | grep -E "NSAudioCaptureUsageDescription|NSLocalNetworkUsageDescription|LSMultipleInstancesProhibited"
```

**What Phil should see:** nothing on the bulbs. In the terminal: an Apple Development
authority, Phil's Personal Team identifier, `runtime` in the flags, both usage description
strings, and `LSMultipleInstancesProhibited => 1`. That last one is what stops a leftover
Glowbeat holding UDP 4002 and stealing every bulb reply from this run.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `project.yml` (signing settings, `INFOPLIST_FILE`), `App/Info.plist`.
An ad hoc or unsigned build gets a new identity every rebuild, so macOS treats it as a
different app and throws away the audio and local network grants every time. Do not
continue on an unsigned build. Everything below will produce fake failures.

---

## Step 0b: Window layout, the sidebar and the bulb strip

No lights change except the one flash Phil asks for. No warning needed beyond that.

Open Glowbeat. The window is a sidebar and a pane now, not one long scroller.

**What Phil should see:**

1. **Four rows in the sidebar**, Bulbs, Party, Scenes, Schedule, each with a second line
   under it: "6 on" or "2 of 6 on", "Off" or "On, Pulse, Punchy", "Off" or the scene's
   name, "Off" or "Wake 7:00 AM, sleep 10:00 PM". Turn a bulb off from the Bulbs pane and
   the Bulbs line has to change within a poll.
2. **The pane he was last on** comes back when he quits and reopens Glowbeat.
3. **The bulb strip along the bottom** on Party, Scenes and Schedule, and not on Bulbs.
   Six tiles, each with a name, a switch, a brightness slider and a color swatch.
4. **Identify from a tile.** Hover a tile: a small bolt appears at its top right. Click it
   and that bulb, and only that bulb, flashes white twice and goes back to what it was.
   The bolt is dimmed while Party Mode or a scene is running.
5. **Drag a tile.** Drag the third tile onto the first. The strip reorders, the Bulbs pane
   shows the same new order, and every bulb nobody has named renumbers at once: the bulb
   that was "Bulb 3" reads "Bulb 1" and the two it passed take the numbers it left. A bulb
   Phil has named, say "Kitchen", keeps its name wherever it lands.
6. **The swatch on a tile** opens a popover with a color well and a white slider. Changing
   either has to reach that bulb and only that bulb.

**Cannot be tested with six bulbs:** the strip is designed to scroll sideways rather than
wrap once the tiles are wider than the window. Six tiles are 972 points and the window
opens at 1000, so nothing scrolls and the hover chevrons never appear. With seven or more
bulbs, or with the window dragged narrower than about 990 points, the chevrons should
appear on hover at the ends of the strip and move it three tiles at a time. Narrowing the
window is the only way to see it here.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `App/Views/MainWindowView.swift` (the split view and the pane
header), `App/Views/BulbStripView.swift` (the strip and its chevrons),
`App/Views/BulbStripTile.swift` (the tile, its flash and its drag),
`App/AppModel.swift` (`moveBulb(withID:toIndex:)`, `displayName(for:)`).

---

## Step 1: Local Network permission is on for Glowbeat

**Do this before anything else touches the network.** This is the single most likely
reason a working app looks completely dead.

A dev build of Glowbeat was blocked by macOS with no visible prompt at all: no dialog, no
error, discovery just silently found zero bulbs. The fix is a checkbox.

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
```

**What to do:** find Glowbeat in the list and make sure its switch is on. If Glowbeat is
not in the list yet, launch the app once (Step 2), quit it, and look again.

**What Phil should see:** Glowbeat listed under Local Network with the toggle on.

**Pass / fail:** [ ] pass  [ ] fail

**Read this before debugging anything as a "discovery bug":** a command line probe run
from Terminal is exempt from this permission, because it inherits Terminal's own grant.
So the probe script finding all six bulbs while the app finds zero is not a contradiction
and it is not a discovery bug. **"The probe works but the app does not" means this toggle,
every time.** Check it before opening a single Swift file.

**If it fails, look at:** `App/Info.plist` (`NSLocalNetworkUsageDescription` must be
present or macOS will not even offer the toggle), then
`Packages/GoveeLAN/Sources/GoveeLAN/LANSocket.swift` and `LocalInterface.swift`.

### Also confirm: no other Glowbeat instance is running

A second copy of Glowbeat binds UDP 4002 with `SO_REUSEPORT` too, and the kernel hands
each bulb reply to only one of the sockets. A stray instance left over from an earlier
run silently steals bulb replies from the instance you are watching, and from any command
line probe, so discovery reports zero bulbs with nothing in the log to explain it.

```bash
pgrep -fl Glowbeat
lsof -nP -iUDP:4002
```

**What Phil should see:** both commands print nothing. If either prints anything, quit
every Glowbeat instance (`pkill -f Glowbeat.app` if one is not in the Dock) and run them
again until both are empty.

`LSMultipleInstancesProhibited` in `App/Info.plist` stops macOS opening a second copy of
the same app, so a hit here usually means a build sitting in a different folder, or an
instance still running from before that key existed. Check it anyway. It costs two
seconds and it is the cause that looks exactly like a discovery bug.

**Pass / fail:** [ ] pass  [ ] fail

---

## Step 2: Item 1, discovery finds six bulbs within three seconds

**Say to Phil:** "I am launching Glowbeat. Nothing will change on your lights. Watch the
bulb list fill in."

No light changes, so no countdown is needed, but say the line anyway so he is watching the
window at the right moment.

```bash
cd ~/Projects/glowbeat
open build/DerivedData/Build/Products/Debug/Glowbeat.app
```

Three seconds after the window appears:

```bash
screencapture -x -o ~/Desktop/glowbeat-hw-1-discovery.png
open -a Preview ~/Desktop/glowbeat-hw-1-discovery.png
```

**What Phil should see:** six rows in the bulb list, each with a green reachability dot,
inside three seconds of the window appearing. If macOS shows a Local Network prompt,
allow it and note that it appeared. That prompt is expected on macOS 15 and later.

**Record:** how many bulbs appeared, and how long it took.

**Pass / fail:** [ ] pass  [ ] fail   Count: ___ / 6   Seconds: ___

**Baseline:** all six of Phil's H6004 bulbs answer LAN discovery. The Swift package found
6 of 6 after the scan burst fix, which sends the scan request three times, 0.3 s apart,
because a single multicast send found 4, 5, 6 and 6 across four runs. Fewer than six here
is a regression, not bad luck.

**If it fails, look at:**
- Zero bulbs, first cause to rule out: another Glowbeat instance is already running and
  holding UDP 4002, so it is taking every bulb reply. `pgrep -fl Glowbeat` and
  `lsof -nP -iUDP:4002` must both be empty (Step 1). The app itself logs
  "Another process holds UDP 4002" at launch when it sees this.
- Zero bulbs: then Step 1's Local Network toggle. Then `LANSocket.swift`,
  `LocalInterface.swift`.
- Some bulbs, not all: `BulbDiscovery.swift`, specifically `scanRepeatCount`,
  `scanRepeatSpacing` and `replyWindow`.
- Bulbs appear but the dots are gray: `BulbDiscovery.missesBeforeUnreachable` and the
  round bookkeeping in `BulbDiscovery.swift`.
- Bulbs appear slowly, after three seconds: the burst timing in `BulbDiscovery.swift`.
- Check LAN Control is still on for each bulb in Govee Home before blaming the app.

---

## Step 3: Item 2, per bulb and All controls change the real bulbs

**WARN FIRST.** Say to Phil: "I am about to switch every bulb on, set them to 60 percent,
and turn them red, then change only the first bulb to blue. Watch the room." Wait for
"ready", then count down 10 seconds, then run it.

**What to do,** from the app window, in this order:
1. All row, On
2. All row, brightness to 60
3. All row, color well to red
4. The first bulb's own color well to blue

**What Phil should see:** all six bulbs come on, drop to roughly 60 percent, go red
together, then one bulb alone turns blue and the other five stay red. Each change should
land in well under a second. Reachability dots stay green throughout.

**Then check the readback.** Wait about 10 seconds without touching anything. Outside
Party Mode `devStatus` polls every 10 seconds, so each row's brightness slider and color
well should settle on what was just set and stay there.

**Pass / fail, lights:** [ ] pass  [ ] fail
**Pass / fail, readback matches:** [ ] pass  [ ] fail

**If it fails, look at:**
- Nothing happens at all: Step 1 again, then `BulbController.swift`.
- Power or brightness works but color does not: `LANMessage.colorwc` and `GoveeRGB.swift`.
- Some bulbs respond and others do not: `BulbController` fan out, and whether the
  non-responding bulb's dot went gray (that is `BulbDiscovery`, not the controller).
- Lights are right but the sliders snap back to an old value: `StatusPoller.swift` and
  `ControlSettle` in `App/Views/BulbListView.swift`.
- Sliders show what was set but the bulbs did not change: the app is believing its own
  intent instead of the bulb. Look at `StatusPoller` decoding in `LANMessage.swift`.

---

## Step 4: Item 3, Party Mode with music, all three effects

**WARN FIRST.** Say to Phil: "Start some music with a clear beat. I am turning on Party
Mode. Watch whether the bulbs follow it." Wait for "ready", then count down 10 seconds,
then turn Party Mode on.

Audio capture is already granted on this Mac, so expect no permission prompt here. If one
appears, allow it and note that the grant was lost, which usually means the build identity
changed (see Step 0).

Run each effect for about 30 seconds: **Pulse**, then **Spread**, then **Wave**, then **Glow**.

**What Phil should see, for each effect:**
- The Level meter in the Party panel moves with the music.
- **Pulse:** every bulb brightens and dims together on the beat. The color holds for four
  beats (never less than about a second on a fast track) and then fades to the next
  palette color over a fraction of a second, while every beat still flashes. A color
  change on every kick, or a hard cut from one color to the next, is a fail (changed
  2026-09-23).
- **Spread:** different bulbs react to different parts of the music. Bass hits move some
  bulbs, cymbals and vocals move others. Out of the box the bulbs are dealt Bass, Mid,
  High and round again down the list; the sub-step below is where that is changed. All of
  them share one hue family at any moment: a deeper shade on the bass bulbs, the palette
  color on the mid bulbs, a paler shade on the treble bulbs. **Every group reaches full
  brightness on its beat**; Bass is told apart by its shade, not by being dimmer (changed
  2026-09-23). Three unrelated colors is a fail.
- **Wave:** the color visibly travels from bulb to bulb, in order along the row. When the
  color changes, the first bulb fades into the new one and it travels in behind the old
  one as a band.
- **Glow:** every bulb shares one color that brightens with how loud the music is and
  dims as it drops, with the hue drifting slowly through the palette. It follows volume,
  not beats, so it should breathe with the music rather than hit with it. Worth trying on
  something without drums as well.

**Expect pulsing and breathing, not strobing.** Glowbeat sets color with `colorwc`, and
H6004 firmware fades between colors instead of snapping. The bulbs will look like they are
breathing with the music. Sharp on and off flashes would be the bug, not the goal.

**Pass means all three read as deliberate rather than random,** judged by Phil watching,
not by the meter.

| Effect | Pass / fail | Notes |
|---|---|---|
| Pulse | [ ] pass [ ] fail | |
| Spread | [ ] pass [ ] fail | |
| Wave | [ ] pass [ ] fail | |
| Glow | [ ] pass [ ] fail | |

**If it fails, look at:**
- **Level meter sits at zero:** this is the audio path, not the LAN path. Check Privacy
  and Security, Screen and System Audio Recording for Glowbeat, and check the Mac is not
  muted and something is actually playing. Then
  `Packages/AudioTap/Sources/AudioTap/SystemAudioTap.swift`.
- Meter moves but bulbs do nothing: `App/Party/PartyEngine.swift` and
  `App/Model/FrameBridge.swift`.
- Bulbs move but the motion looks random: `Packages/Effects/Sources/Effects/BeatDetector.swift`
  and the effect's own file (`PulseEffect.swift`, `SpreadEffect.swift`, `WaveEffect.swift`,
  `GlowEffect.swift`).
- **Bulbs stay at the dim color through loud music:** the party gate is set above the
  music. Drag the marker on the Trigger Level bar down. See Step 4a.
- Glow never brightens, or sits at full brightness: `GlowEffect.swift` and
  `Packages/Effects/Sources/Effects/LoudnessEnvelope.swift`.
- Bulbs stutter, lag behind the beat, or drop off Wi-Fi: lower "Most updates per bulb,
  per second" in Settings (past six bulbs Glowbeat already lowers it on its own, see Step
  4d), then look at `StreamRateLimiter.swift` and `ColorDeduper.swift`.
- Spread puts every bulb on the same band, or none of them move: `SpreadEffect.swift`
  and `BandMapper.swift`.
- Wave does not travel in order: `WaveEffect.swift` and the bulb ordering in
  `App/Views/BulbListView.swift`.
- Wave travels too fast or too slow to read: that is the Travel slider now, see the
  sub-step below.

### Also: Wave's Travel slider sets how fast the color crosses the room

**WARN FIRST.** Say to Phil: "Same music, Party Mode still on. I am putting the effect
back on Wave and dragging one slider. The color is going to crawl, then race." Wait for
"ready".

Travel only exists while **Wave** is the chosen effect. It sits right under the effect
picker, above Palette, and it is not in Settings.

1. Choose **Wave**. A **Travel** slider appears under the picker, reading `10 bulbs/s`.
2. Choose **Pulse**. The Travel slider must disappear. Choose **Wave** again; it comes
   back at the value it had.
3. Drag **Travel** all the way down to `1 bulbs/s`. Watch for 30 seconds.
4. Drag **Travel** all the way up to `15 bulbs/s`. Watch for 30 seconds.
5. Put it back to about 10, quit Glowbeat and reopen it. Travel must still read 10.

**What Phil should see:**
- At **1 bulb/s** the color crawls along the row, taking about six seconds to cross six
  bulbs. Each bulb holds its color for a full second before the next one takes it.
- At **15 bulbs/s** it races, close to being everywhere at once.
- At every speed the room still reacts **on the beat**: the first bulb in the list lights
  the moment a beat lands, even at 1 bulb/s where the color is only just starting to move.
  A room that only reacts once a second at the slow end is a fail.
- The slider snaps to whole numbers and the readout never clips: `15 bulbs/s` has to fit.
- The slider takes effect while it is being dragged, not only when released.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:**
- Travel shows for effects other than Wave, or never shows:
  `App/Views/PartyPanelView.swift` (`travel`).
- Dragging it does nothing: `AppModel.setWaveTravelSpeed` and
  `PartyEngine.setWaveTravelSpeed`.
- The speed is lost when the effect is switched away from Wave and back:
  `PartyEngine.setEffect(_:)`, which has to hand the new Wave the stored speed.
- The slow end still hops once per tick, or the fast end does not: the hop accumulator in
  `Packages/Effects/Sources/Effects/WaveEffect.swift`.
- The room stops reacting on the beat at a slow Travel: the beat has to light the first
  bulb on the tick it lands, in the same file.
- Travel is forgotten after a relaunch: `App/Model/GlowbeatSettings.swift`.

### Also: the Bulbs row puts each bulb on Bass, Mid or High

**WARN FIRST.** Say to Phil: "Same music, Party Mode still on. I am putting the effect on
Spread and moving two bulbs onto the hats. Watch those two." Wait for "ready".

The **Bulbs** row only exists while **Spread** is the chosen effect. It sits right under
the effect picker, above Palette, and it is not in Settings. Each bulb gets its name and a
Bass / Mid / High control, two to a row in a normal sized window.

1. Choose **Spread**. A **Bulbs** section appears under the picker, one cell per bulb, in
   the same order as the bulb list above.
2. Choose **Pulse**. The Bulbs section must disappear. Choose **Spread** again; it comes
   back with the same choices.
3. Put **two bulbs on High**. Play something with clear hi hats or a shaker. Watch those
   two for 30 seconds.
4. Put **every bulb on Bass**. Watch for 30 seconds.
5. Rename a bulb in the list above, then look at the Bulbs row: the new name is there.
6. Drag a bulb to a different place in the bulb list. Its band must go with it.
7. Quit Glowbeat and reopen it. Every choice must still be there.

**What Phil should see:**
- The **two bulbs on High** flicker on the hats and the shaker, and sit still through the
  kick. They are the palest bulbs in the room, because High runs toward white.
- With **every bulb on Bass** the whole room thumps together on the kick, like Pulse, at
  full brightness, in Bass's deeper shade of the palette color.
- A bulb with no choice made for it keeps the old behavior: first bulb Bass, second Mid,
  third High, and round again.
- Moving a bulb up the list takes its band with it. The band belongs to the bulb, not to
  the slot.
- The room still changes color on the kick even with nothing on Bass. Only a bass beat
  moves the palette along, whoever is listening to it.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:**
- The Bulbs section shows for effects other than Spread, or never shows:
  `App/Views/PartyPanelView.swift` and `App/Views/SpreadBulbsSection.swift`.
- Clicking a segment does nothing to the room: `AppModel.setSpreadGroup(_:for:)` and
  `PartyEngine.setSpreadAssignments(_:)`.
- Every bulb on Bass lights only some of them: the assignment is not reaching the effect,
  so `PartyEngine.applySpreadAssignmentToEffect` and `SpreadEffect.setAssignment(_:)`.
- A band jumps to a different bulb after a reorder: the map is keyed on the bulb id, so
  `PartyEngine.orderedSpreadAssignment` and `AppModel.resolvedSpreadAssignments`.
- The choices are forgotten after a relaunch: `spreadAssignments` in
  `App/Model/GlowbeatSettings.swift`.

### Also: Confetti gives every bulb its own color (added 2026-09-23)

**WARN FIRST.** Say to Phil: "Party Mode stays on. I am turning on Confetti, under the
palette. Every bulb should take its own color. Watch the bulbs next to each other." Wait
for "ready", then count down 10 seconds.

1. Choose **Pulse** and a palette with five colors (Party). Turn **Confetti** on.
2. Watch for 30 seconds, then do the same on **Spread**, **Wave** and **Glow**.
3. Turn Confetti off, then on again, without stopping Party Mode.
4. Choose **Fire**, then **Blacklight**: their colors are close to each other, which is
   where two neighbors are most likely to meet.
5. Quit Glowbeat and reopen it. The switch is still on.

**What Phil should see:**
- **Pulse:** every bulb flashes on the same beat, each in its own palette color. No two
  bulbs next to each other in the bulb order ever show the same color, including while
  they fade to their next colors every four beats.
- **Spread:** each bulb in its own palette color, in its band's shade (Bass deeper, High
  paler). Two bulbs on the same band are no longer one color.
- **Wave:** the colors stream in from the first bulb at the Travel speed, each different
  from the one behind it. Turning Confetti on or off turns the room over as the wave
  travels, rather than repainting it at once.
- **Glow:** every bulb drifts slowly through the palette from its own starting color.
- The switch acts at once and fades the room apart or back together; nothing restarts.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:**
- Two neighbors match: `Packages/Effects/Sources/Effects/ConfettiScatter.swift`. Check the
  bulb order first: neighbors are neighbors in the list, not in the room.
- The switch does nothing until Party Mode restarts: `AppModel.setPartyConfetti(_:)` and
  `PartyEngine.setConfetti(_:)`.
- It works on one effect and not another: that effect's `setConfetti(_:)`.
- It is forgotten after a relaunch: `partyConfetti` in `App/Model/GlowbeatSettings.swift`.

---

## Step 4a: The party gate quiets the room and lets it back

**WARN FIRST.** Say to Phil: "Same music, Party Mode still on. I am going to drag the
marker on the Trigger Level bar. The bulbs will go quiet, then come back." Wait for
"ready".

In the Party Mode panel, the **Trigger Level** row carries three things: the moving bar
is the level Glowbeat is hearing, the faint line riding on top is the peak, and the accent
colored line is the **marker**. The percentage to the right of the bar is where the marker
sits. That one marker is the whole reaction control, so moving it changes both what the
room ignores and how readily a beat counts, which is what Step 5 covers.

1. Drag the gate marker **above** where the level bar is bouncing to.
2. Watch for about 10 seconds.
3. Drag it back **below** the bouncing level.
4. Watch for about 10 seconds.

**What Phil should see:**
- Above the level: every bulb glides down to the palette's dim color over the Fade (about
  0.3 s on Punchy) and stays there, rather than dropping there in one step (changed
  2026-09-23). Dim, not off, and not flickering back and forth at the edge. On Wave the
  last highlight keeps traveling while it fades.
- Below the level: the room reacts to the music again, and the effect starts from the
  palette's first color rather than resuming somewhere further along.
- The room responds while the marker is still being dragged, not only when it is released.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:**
- Bulbs flicker between color and dim at the threshold: the hysteresis in
  `App/Model/PartyGate.swift`.
- Bulbs go fully off rather than dim: `App/Party/PartyEngine.swift`, the dim base written
  when the gate is shut.
- The marker moves but nothing changes until it is released: `App/Views/LevelMeter.swift`
  and `AppModel.setPartyGate`.
- The marker quiets the room but does not change how picky it is: `PartyEngine.setGate`,
  which is where the beat sensitivity is derived from the same value.
- The gate is forgotten after a relaunch: `App/Model/GlowbeatSettings.swift`.
- Nothing ever quiets, whatever the gate is set to: remember the level the gate judges is
  auto-gained. A long quiet passage is renormalized back to full scale within fifteen to
  twenty seconds, so the gate is for short gaps, short intros and true silence.

---

### Also: Always react turns the marker off

**WARN FIRST.** Say to Phil: "Same music, Party Mode still on. I am going to tick Always
react, then turn the music down. The lights should keep reacting." Wait for "ready".

The checkbox on the right under the Trigger Level row is for the case where the marker is
the wrong answer: something quiet playing, and a room that should move with it anyway.

1. Drag the marker **above** the bouncing level, so the room goes dim as it did above.
2. Tick **Always react**. The room starts reacting again.
3. Confirm the marker and the percentage beside it are grayed out and the marker cannot be
   dragged at all. The moving bar under it must keep moving.
4. Turn the music down low, to where the level bar barely moves. The lights keep reacting.
5. Untick it. The marker comes back solid and draggable, still exactly where it was left,
   and the room goes dim again because the marker is still above the level.
6. Drag the marker back below the level and put the volume back.

**What Phil should see:** the room reacts at any volume while the box is ticked, and goes
back to exactly the behavior of the step above when it is unticked. It must still be
pulsing: a room that sits solidly lit rather than moving with the music is the failure
this step exists to catch.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:**
- The room sits solidly lit rather than pulsing: `App/Model/GlowbeatSettings.swift`
  (`alwaysReactsSensitivity`), the beat sensitivity pinned while the marker is grayed.
- The marker can still be dragged: the `isGateEnabled` path in
  `App/Views/LevelMeter.swift`.
- Unticking it does not put the old marker back: `PartyEngine.applyReaction` and the
  `gateMarker` it reads.
- The room does not react at low volume: remember the level is auto-gained, so what this
  really proves is the gate, not the volume. `PartyEngine.applyReaction` again.
- Glow never brightens with the box ticked: the effect has to be handed a gate of 0.
- The box is forgotten after a relaunch: `App/Model/GlowbeatSettings.swift`.

---

## Step 4b: Feel, and the four sliders behind Advanced

**WARN FIRST.** Say to Phil: "Same music, Party Mode still on. I am going to open Advanced
and move four sliders. The room will get darker and brighter between beats, and the beats
will get softer and longer." Wait for "ready".

The Party panel shows **Trigger Level** and its **Always react** checkbox, then Effect,
Palette and the **Feel** row. The four sliders live behind the **Advanced** disclosure
under Feel, folded away on a fresh install.

### First: the Feel row

Feel is four ready made settings of those same four sliders: tap one instead of learning
what Darkest, Brightest, Snap and Fade mean. It sits directly above Advanced, so open
Advanced first and leave it open, then watch the sliders move as you tap.

1. Tap **Punchy**. Watch the room for 10 seconds.
2. Tap **Mellow**. Watch for 10 seconds.
3. Tap **Dreamy**. Watch for 10 seconds.
4. Tap **Tight**. Watch for 10 seconds.
5. Now drag **Fade** a little way with your own hand.
6. Tap **Punchy** again.
7. Quit Glowbeat and reopen it.

**What Phil should see:**
- Each tap moves all four sliders at once and the room changes with them. The readouts
  land exactly on these numbers:

  | Feel | Darkest | Brightest | Snap | Fade | What it should feel like |
  |---|---|---|---|---|---|
  | Punchy | 10% | 100% | instant | 0.3 s | Fast and bright. |
  | Mellow | 35% | 80% | 0.06 s | 1.5 s | Low and slow. |
  | Dreamy | 20% | 70% | 0.25 s | 3.0 s | Soft hits, long settle. |
  | Tight | 0% | 100% | instant | 0.1 s | Sharp flicker, goes dark between hits. |

- The tapped feel is highlighted in amber and the line under the row says what it is.
- Tapping a feel never changes Trigger Level, Always react, Travel, the effect or the
  palette. If the marker or the palette moves, that is a fail.
- **Dreamy** and **Tight** should be obviously different rooms: Dreamy swells and hangs,
  Tight cracks and goes dark between hits.
- Dragging Fade by hand drops the row to **Custom** the moment the value moves.
- Tapping Punchy again puts it straight back to Punchy.
- After the relaunch the row still says Punchy. It is the four values that are
  remembered, not the name, so a relaunch that shows Custom means one of the four did
  not persist.

### Then: the disclosure itself

1. Confirm the panel opens showing Trigger Level and its checkbox only, with a collapsed
   **Advanced** row below them and no other sliders on screen.
2. Click **Advanced**. Four sliders appear: Darkest, Brightest, Snap and Fade.
3. Quit Glowbeat and reopen it. Advanced must still be open.
4. Open **Settings** (gear in the toolbar). All four sliders are there too, with no
   disclosure to open.

### Then: Darkest and Brightest

Every effect reports how hard it is hitting, from calm to a full hit, and those two
sliders are where calm and a full hit land.

1. Drag **Darkest** up to about 40 percent. Watch for 10 seconds.
2. Drag **Brightest** down to about 50 percent. Watch for 10 seconds.
3. Put Darkest back to about 10 percent and Brightest back to 100 percent.
4. Drag Darkest all the way up, into Brightest.

### Then: Snap and Fade

Snap is the attack, how fast a hit arrives. Fade is the release, how long it takes to
settle. Both read in seconds rather than a percentage, and Snap reads `instant` once it is
past about 80 percent, where the rise finishes inside a single tick. A caption under each
one says which way is faster. Run these on **Pulse** first, then repeat the Snap drags on
**Wave** and **Spread**: Snap driving all three is the fix this step is here to check.

5. Drag **Snap** all the way down. Watch for 10 seconds.
6. Drag **Snap** all the way up. Watch for 10 seconds.
7. Drag **Fade** all the way down, then all the way up, watching after each.
8. Put both back to where Glowbeat ships them, which is the **Punchy** feel: Snap at
   `instant` and Fade at `0.3 s`. Tapping **Punchy** on the Feel row does it in one
   click.

**What Phil should see:**
- With Darkest raised, the room never drops to near black between beats. It sits lit in
  the palette's color and the beats ride on top of that.
- With Brightest lowered, the beats stop reaching full brightness. The whole room works
  in a narrower, calmer band, still clearly following the music.
- With **Snap down**, every beat swells in over about a quarter second rather than
  cracking on. It must still reach full brightness, just later: a hit that is only ever
  dimmer is the slider behaving as a brightness control, which is a fail.
- With **Snap up**, beats hit instantly, the way the app behaved before these sliders
  existed, and the readout says `instant`. This must look the same on Pulse, Wave and
  Spread. An effect that ignores Snap entirely is a fail.
- With **Snap down**, the readout counts up to "0.25 s". The readout column must not clip
  the word `instant` in either the Party panel or Settings.
- With **Fade down**, the room flickers tightly and goes dark between hits. With Fade up
  it smears into a slow breath that outlasts several beats. The readout says the time,
  "0.1 s" through "5.0 s".
- All four sliders take effect while they are being dragged, not only when released.
- The two brightness sliders never meet: pushing Darkest into Brightest pushes Brightest
  up ahead of it, and the room keeps reacting.

### Also: Reset and Save as default (added 2026-09-14)

At the bottom of Advanced, under the Fade caption, there are two buttons on one row:
**Reset** (with a circular arrow) and **Save as default** (amber). They only ever touch
those four sliders.

1. Open Advanced on a fresh look. Both buttons should be **dimmed**.
2. Tap **Mellow**, or drag any one of the four sliders.
3. Press **Reset**.
4. Now dial in a room you actually like: move any of the four.
5. Press **Save as default**.
6. Tap **Dreamy**, then press **Reset**.
7. Quit Glowbeat, reopen it, tap **Punchy**, and press **Reset** again.

**What Phil should see:**
- Both buttons are dimmed whenever the four sliders already are the default, and both
  come alive the moment any one of them moves. Dimmed means there is nothing to do.
- Step 3 puts all four sliders back to Punchy (10% / 100% / instant / 0.3 s) and the Feel
  row says **Punchy**. The room changes as it happens: nothing has to be restarted.
- Step 5 flashes **Saved** with a checkmark for about a second and a half, then goes back
  to saying "Save as default", dimmed.
- Step 6 puts the sliders back to **what he saved**, not to Punchy.
- Step 7 still goes back to what he saved: a default outlives a relaunch.
- Hovering **Reset** says "Back to your saved default" once something is saved, and "Back
  to Punchy" before that.
- Neither button ever moves Trigger Level, Always react, Travel, the effect or the
  palette. If the marker or the palette moves, that is a fail.
- The same two buttons are in Settings, under the same four sliders, and do the same
  thing.

### Also: the panel's new look, in light and in dark

The Party panel was restyled on 2026-09-14. This is a look at it, not a test of behavior.

1. Look at the whole panel top to bottom with Party Mode running.
2. Switch macOS to Light Appearance (System Settings > Appearance) and look again.
3. Switch back to Dark.

**What Phil should see:**
- Trigger Level sits on a translucent sheet with its own big percentage, and it is the
  only thing on a sheet. Everything else sits flat on the window.
- Amber appears in exactly four places: the marker on the meter, the chosen Effect, the
  chosen Feel, the ring around the chosen palette, and the Party Mode switch. Amber
  anywhere else is a fail.
- The meter itself is gray. The bar lights up in gray as the music plays, and the marker
  is the only colored thing on it.
- Light Appearance is readable everywhere: no white text on white, no invisible captions,
  and the amber is a darker gold rather than the same bright one.
- Pressing a palette chip, a segment or the checkbox makes it shrink very slightly under
  the pointer.
- Nothing jumps sideways as numbers change: the percentages and times are monospaced.
- Three faces, added 2026-09-14. "Party Mode" at the top and the five names on the Feel
  row (Punchy, Mellow, Dreamy, Tight, Custom) are in the rounded face: softer, friendlier
  letters than everything around them. Effect, Palette, Bulbs and every label and caption
  are the plain system face. Every live number (the big Trigger Level percentage, and
  Darkest, Brightest, Snap, Fade and Travel out at the right) is in the typewriter face.
  No readout may be clipped or run into the panel's edge in either appearance.

**Pass / fail (the whole of Step 4b):** [ ] pass  [ ] fail

**If it fails, look at:**
- A feel does not move all four sliders, or the row will not leave Custom:
  `App/Model/PartyPreset.swift`, `GlowbeatSettings.matchingPreset` and
  `AppModel.applyPartyPreset`.
- The look is wrong in one appearance only: `App/Views/PartyStyle.swift` and the
  `PartyAccent` / `PartySegmentRaised` color sets in `App/Assets.xcassets`.
- Reset or Save as default is live when the sliders are already on the default, or dead
  when they are not: `AppModel.canResetAdvanced` / `canSaveAdvancedAsDefault` and
  `AdvancedValues.matches`.
- Reset goes back to Punchy when something was saved, or a saved default does not survive
  a relaunch: `GlowbeatSettings.savedAdvancedDefault` and `SettingsStore`.
- The buttons look wrong or the "Saved" flash is too quick to read:
  `App/Views/AdvancedDefaultRow.swift` and `App/Views/PartyButtonStyle.swift`.
- Advanced is open on a fresh install, or forgets its state:
  `App/Model/GlowbeatSettings.swift` (`showsPartyAdvanced`) and
  `AppModel.setPartyAdvancedExpanded`.
- Nothing changes while dragging: `App/Views/PartyPanelView.swift` (`LabeledValueSlider`,
  `PartySliders`) and `AppModel.setPartyFloor` / `setPartyCeiling` / `setPartySnap` /
  `setPartyFade`.
- Snap does nothing on Pulse, Wave or Spread: that effect's file in
  `Packages/Effects/Sources/Effects/`, and `EffectTiming.risen(from:over:)`. Each of the
  three ramps its level toward a full hit; none of them may jump straight to it.
- Snap or Fade is lost when the effect is switched mid session:
  `PartyEngine.setEffect(_:)`, which has to hand the new effect the current timing.
- The room goes black between beats however high Darkest is:
  `Packages/Effects/Sources/Effects/EffectOutput.swift` (`rendered(floor:ceiling:)`) and
  the mapping in `App/Party/PartyEngine.swift`.
- An effect ignores the range: that effect's file. Every effect must report a full
  strength color plus an intensity and never dim its own output.
- The range is forgotten after a relaunch: `App/Model/GlowbeatSettings.swift`.

---

## Step 4c: Scenes run without any music at all

**WARN FIRST.** Say to Phil: "I am turning the music off and switching on a Scene. The
bulbs will change on their own, slowly." Wait for "ready", then count down 10 seconds.

Stop the music and switch Party Mode off. The **Scenes** section sits between the bulb
list and the Party panel: a switch, a picker with five scenes, and a Speed slider.

Run each of these for about 30 seconds.

| Scene | What Phil should see |
|---|---|
| Breathe | Every bulb brightens and dims together, about one breath every six seconds at 1x, taking the next palette color each breath. |
| Color flow | The palette drifts along the bulbs in list order, one bulb step every two seconds at 1x, crossfading rather than stepping. |
| Candle | A warm amber flicker, each bulb doing its own thing. All six dipping at once is a fail. |
| Static | One palette color per bulb in list order, holding still. Nothing moves at all. Turn **Single color** on and every bulb takes the palette's first color instead; turn it off and the palette spreads back along them. |
| Sunset | Starts at a bright warm white and works down through orange. A progress bar appears with the time left. |

**Then check the rules around them:**
1. With a scene running, switch **Party Mode** on. The scene must switch itself off.
2. With Party Mode running, switch **Scenes** on. Party Mode must switch itself off.
3. Change the **palette** while a scene runs. The scene must pick it up.
4. Drag **Speed** while a scene runs. Breathe or Color flow must visibly speed up or slow
   down without restarting.
5. Reorder the bulb list while **Color flow** runs. The flow must follow the new order.
6. Switch a scene **off**. The bulbs stay on the color they were last given, they do not
   jump anywhere and they do not go out.
7. Quit Glowbeat with a scene running, and relaunch. The picker must still show that
   scene and its speed, the Single color switch must still be where it was left, and
   **nothing may be running**.

**For Sunset specifically,** set Speed to 4x, which makes the timeline five minutes rather
than twenty, and let it run to the end.

**What Phil should see:** the bulbs work down to a deep, dim orange, then **switch off**,
and the Scenes switch goes back to off by itself.

| Scene | Pass / fail | Notes |
|---|---|---|
| Breathe | [ ] pass [ ] fail | |
| Color flow | [ ] pass [ ] fail | |
| Candle | [ ] pass [ ] fail | |
| Static | [ ] pass [ ] fail | |
| Sunset, including the lights out at the end | [ ] pass [ ] fail | |
| Scenes and Party Mode are mutually exclusive | [ ] pass [ ] fail | |
| Speed, palette and bulb order all apply live | [ ] pass [ ] fail | |
| Nothing runs on launch, the picker remembers | [ ] pass [ ] fail | |

**If it fails, look at:**
- Nothing happens at all: `App/Scenes/SceneEngine.swift`, then the bulb list. Scenes only
  run on reachable bulbs.
- A scene runs but stutters: it sends four times a second, so this is the same rate limit
  path as Party Mode. `StreamRateLimiter.swift` and `ColorDeduper.swift`.
- Static sends over and over: `ColorDeduper` is not doing its job in `SceneEngine.tick`.
- A scene and Party Mode both run: `AppModel.setSceneEnabled` and
  `AppModel.setPartyModeEnabled`.
- Sunset never ends, or ends without switching the bulbs off:
  `Packages/Effects/Sources/Effects/SunsetScene.swift` and `SceneEngine.finish`.
- A scene starts itself at launch: nothing may call `setSceneEnabled(true)` from
  `startServices`. Check `App/AppModel.swift`.

---

## Step 4d: Ten bulbs keep up, every bulb reaches real full brightness, and the stop lands right

Three fixes from 2026-09-23 (v1.2 addendum section T), all about what the room does
rather than what the panel shows. Run this with every bulb on, ten at the time of writing.

### First: full brightness means full

**WARN FIRST.** Say to Phil: "I am setting the room to a dim color, then starting Party
Mode. The bulbs should jump to their full brightness as it starts, not stay dim." Wait
for "ready", count down, then: on the Colors pane set Brightness to 30% and click any
swatch, wait five seconds, then switch Party Mode on (Punchy, Brightest 100%) with music.

**What Phil should see:** the room comes up to the bulbs' own full brightness as Party
Mode starts, before or with the first hit, and a hit at Brightest is as bright as the
bulbs go. Before the fix the whole session ran at 30 percent of Brightest. Switch Party
Mode off: the settle color is at full brightness too, not back at 30 percent. That is by
design (there is nothing trustworthy to put back), and the next still color or Light
transition sets its own.

**Also:** start any Scene from the same dim room. It too comes up to full brightness first.

**Pass / fail:** [ ] pass  [ ] fail

### Then: ten bulbs keep up (the room's send budget)

Open Settings, General. The slider is now **"Most updates per bulb, per second"**, and
with ten bulbs its readout says **"10 (6 with 10 bulbs)"** (or "6" alone if Phil's stored
ceiling is six, which it was). The caption reads "Glowbeat lowers this automatically when
you have many bulbs, so the network keeps up."

**WARN FIRST**, then run the dense track that felt jerky and late on 2026-09-23, Pulse
and Wave, two minutes each.

**What Phil should see:** hits land together on every bulb and on time, and nothing
paused. The ten bulbs share sixty colors a second (six each), each tick's colors leave
about 20 ms apart rather than in one burst, and status polls stretch to every 1.7 s so
the room is asked six times a second, not ten.

**Optional, the numbers:** `defaults write com.philwoolley.glowbeat partyTrace -bool true`
before starting Party Mode, then read the `net` rows in
`~/Library/Logs/Glowbeat/party-trace-*.csv`: colorwc at or under 60 a second, the largest
burst inside 10 ms two or three, devStatus about six a second. `defaults delete
com.philwoolley.glowbeat partyTrace` afterwards.

**Pass / fail:** [ ] pass  [ ] fail   Readout seen: __________

### Then: the stop lands on the right thing

**WARN FIRST** each time.

1. **The light mode's white wins.** Set the Light card to Daylight. Start Party Mode with
   music. While it plays, switch the Light card to **Night** (a mode picked while Party
   Mode owns the room is held back). Switch Party Mode off. **The room goes to the warm
   white, and stays there.** Before the fix it flashed white and ended on the palette's
   dim purple.
2. **Nothing held back, the room settles.** Start Party Mode again and switch it off
   without touching the Light card. **The room settles on the palette's dim base**, as
   it always has.
3. **A color picked mid session is the last word.** Start Party Mode, and while it plays
   click a swatch on the Colors pane. **The room ends on that color**, with no dim flash
   and no party color landing after it.

**Pass / fail:** 1 [ ] pass [ ] fail   2 [ ] pass [ ] fail   3 [ ] pass [ ] fail

**If it fails, look at:** `App/Party/PartyEngine.swift` (`setFullBrightness`, `streamRate`,
`stream(_:across:at:through:)`, `stop(settle:)`), `App/AppModel.swift`
(`switchPartyModeOff`, `partyPollInterval`, `applyStatus`),
`App/Schedule/LightModeEngine.swift` (`setSuspended(_:after:)`),
`Packages/GoveeLAN/Sources/GoveeLAN/StreamRateLimiter.swift`.

---

## Step 5: Item 4, the marker sets how much the room reacts

**WARN FIRST.** Say to Phil: "Same music, Party Mode still on. I am going to drag the
marker on the Trigger Level bar from one end to the other. Watch how often the lights react."
Wait for "ready", then count down 10 seconds.

There is no Sensitivity slider any more. The marker on the **Trigger Level** row is the whole
control: it is both the level the room has to clear before anything happens and, derived
from the same value, how readily Glowbeat calls something a beat. Low marker, reacts to
everything. High marker, only the loud hits.

Drag the marker to the far left, watch for 20 seconds. Drag it to the far right, watch for
20 seconds. Then leave it about a third of the way up.

Then one more, on a dense track: put a hip hop or trap mix on, set the marker to about 70
percent, and watch for 30 seconds. The room must keep pulsing on the kicks. Long dead
stretches here are the failure this step exists to catch, because a dense mix keeps the
bass band busy between kicks and a kick only reaches about 1.5 to 1.6 times the rolling
mean. Since 2026-09-14 the marker asks for 1.65 times the mean at its strictest and 1.2
times it at its loosest, so no marker position should starve.

**What Phil should see:** clearly more reactions with the marker low and clearly fewer,
only on the obvious hits, with it high. The change happens while the marker is moving, not
on release. Neither end should be dead: even at the very top the loudest hits still land,
and at the very bottom the room still reacts to music rather than sitting on full.

**Pass means the difference is obvious to Phil without being told which end is which.**

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `App/Model/GlowbeatSettings.swift`
(`derivedSensitivity(forGate:)`, the 0.1 to 0.95 clamps), `App/Party/PartyEngine.swift`
(`setGate`, which is the one place the detector is moved), and
`Packages/Effects/Sources/Effects/BeatDetector.swift` for the threshold that sensitivity
maps onto.

### Also: the gear in the toolbar opens Settings

No lights change. No countdown needed.

Click the **gear** at the top right of the main window.

**What Phil should see:** the Settings window opens, the same one Command comma opens. A
second click while it is already open brings it to the front rather than opening another.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `App/Views/MainWindowView.swift` (the `SettingsLink` toolbar
item) and the `Settings` scene in `App/GlowbeatApp.swift`.

### Also: the window fits a small display

No lights change. No countdown needed.

Click the triangle beside **Scenes**, and then the one beside **Party Mode**, to close
both sections. Then drag the bottom edge of the window up as far as it will go, reopen
both sections, and drag it up again.

**What Phil should see:** each section folds away leaving its switch on the header row, so
Party Mode can still be turned on with the section closed. With both closed the window
shrinks to little more than the bulb list and the status line. With them open on a short
window the panels scroll rather than being cut off. Which sections are open survives a
quit and relaunch.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `App/Views/MainWindowView.swift` (the `DisclosureGroup` sections
and the scroller's own minimum height) and `App/Model/GlowbeatSettings.swift`
(`showsScenesSection`, `showsPartySection`).

---

## Step 6: Item 5, phone takeover pauses inside two seconds

**WARN FIRST.** Say to Phil: "Party Mode stays on. Please open Govee Home and change the
brightness of any one bulb. I am timing how long Glowbeat takes to notice and pause."
Wait for "ready", then count down 10 seconds, then have him make the change.

**What Phil should see:** within about two seconds the bulbs stop following the music and
an orange Paused banner appears reading **"Paused: brightness was changed from the Govee
app."** with a Resume button.

Glowbeat polls `devStatus` every 1 second while Party Mode runs with up to six bulbs,
and stretches that past six so the room is asked six times a second (1.7 s with ten
bulbs, 2.5 s with fifteen). A power or brightness change is caught on the first poll that
sees it: under two seconds with six bulbs, under about two and a half with ten.

**Wait three seconds after Party Mode starts or resumes before changing the brightness.**
Party Mode sets every bulb to full brightness as it starts and repeats that a second and
two seconds later, so a phone change inside that window is simply put back and never
paused on. It also only judges a bulb's brightness once the bulb has reported the full
brightness at least once (v1.2 addendum section T), which takes one poll.

**Record:** wall clock seconds from his change to the banner, and the exact banner wording.

**Pass / fail:** [ ] pass  [ ] fail   Seconds: ___

Then press **Resume** and confirm the lights start following the music again.

**Resume works:** [ ] pass  [ ] fail

**Now the color only case.** Have Phil change only the color of one bulb from Govee Home,
with Party Mode running. Do it in a quiet moment (pause the music): while the music moves
a bulb, Glowbeat repaints it within a tenth of a second and the phone's color never
stays long enough to be seen, which is Glowbeat winning, not a failure.

**What Phil should see:** a pause, but later than the brightness case. The same color,
one Glowbeat did not send in the last three seconds and is not on the fade between two
it did, has to be seen on three consecutive polls, so expect two to three seconds with
six bulbs (3.3 to 5 with ten, where the polls are 1.7 s apart), with the banner reading
**"Paused: a color was changed from the Govee app."**
A phone sets a color and leaves it; a bulb that is behind or mid fade reports a
different wrong color every poll, and that is not a takeover (2026-09-23, v1.2 addendum
section S).

**Pass / fail:** [ ] pass  [ ] fail   Seconds: ___

**Now the false alarm case (Phil's report, 2026-09-23).** With every bulb in the room on
(ten at the time of writing), run Party Mode on a busy track for ten minutes and touch no
phone. Try Wave with Travel high and Snap at instant, which keeps every bulb changing color.

**What Phil should see:** no Paused banner at all. Before the fix, a bulb that fell a
second behind or was caught mid fade paused the room with "a color was changed from the
Govee app" while nobody had touched anything.

**Record:** minutes run, effect and feel, and any pause with its exact wording.

**Pass / fail:** [ ] pass  [ ] fail   Minutes: ___

**Now the scene case,** which the spec calls out as unverified. Have Phil start a Govee
scene on one bulb during Party Mode.

**Record whether it is detected at all.** If a scene is not detectable, **do not invent a
fix.** Write it into Known limitations exactly as spec section 4.4 allows.

**Result:** [ ] pass  [ ] fail  [ ] known limitation

**Now one bulb switched off at Party start.** Switch Party Mode off. Have Phil turn one
bulb off from Govee Home, or at its wall switch, and leave it off. Then switch Party Mode
on again.

**What Phil should see:** Party Mode starts and keeps running. The bulbs that are on
follow the music. Glowbeat does not pause itself over the bulb that was already off, and
it does not turn that bulb on. A session takes its baseline from the first status report
each bulb sends after it starts, so a bulb that was off before the session began is
simply off, not a takeover.

**Record:** whether Party Mode stayed running for at least ten seconds, and whether the
off bulb stayed off.

**Pass / fail:** [ ] pass  [ ] fail

**Also try a different audio output during Party Mode.** With Party Mode running, have
Phil switch the Mac's output to AirPods, and then to a USB or HDMI device if one is handy,
and switch back to the built in speakers.

**What Phil should see:** the level meter keeps moving and the bulbs keep following the
music after each switch, or, if the tap does drop, the banner says Glowbeat is not hearing
any audio rather than the app silently doing nothing.

**Record:** which outputs were tried and what happened at each switch.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:**
- No pause ever: `App/Model/ExternalChangeDetector.swift` and the takeover handling in
  `App/AppModel.swift`.
- Pauses because one bulb was already off: the lazy baseline in `AppModel.applyStatus`
  and `PartyBaseline`.
- Audio stops after an output switch: `Packages/AudioTap/Sources/AudioTap/SystemAudioTap.swift`
  and the permission reporting in `PartyEngine.applyPermission`.
- Pause takes much longer than two seconds: `AppModel.partyPollInterval` and
  `StatusPoller.setInterval`.
- Pauses on its own with nobody touching a phone: `ExternalChangeDetector` (`colorTolerance`,
  `colorPollsBeforePause`, the fade check and `ColorMismatchRun`),
  `BulbController.takeoverHistoryWindow` and `SentColorHistory`, and the baseline and
  session logic in `AppModel` (`PartyBaseline`, `partySession`).
- Resume does not restart the lights: `PartyEngine.resume()` and `isPartyTransitioning`.

---

## Step 7: Item 6, the audio denied path shows the banner

**WARN FIRST,** even though the lights should not change, because Party Mode is being
turned on again. Say to Phil: "I am going to revoke Glowbeat's audio permission so we can
see the error state. Your lights will not change." Wait for "ready", count down 10 seconds.

```bash
tccutil reset ScreenCapture com.philwoolley.glowbeat
```

Quit and relaunch Glowbeat, turn Party Mode on, and deny or dismiss the prompt.

**What Phil should see:** within about three seconds, a red banner titled **"Glowbeat is
not hearing any audio"** with the detail line about allowing Glowbeat under Privacy and
Security, Screen and System Audio Recording, and an **Open settings** button that lands on
that pane.

**Since 2026-09-22 this banner is only for a Party session that has not heard anything at
all** (or a tap that would not open). A denied tap never hears anything, so this step
still raises it. A pause after music has played does not; see "a pause in the music is
not an error" below.

**About the wording:** the banner deliberately also mentions checking that something is
playing and that the Mac is not muted. Glowbeat tries to tell "denied" apart from "silent"
by reading the system output volume, and on Phil's output device that read returns nil, so
the app cannot distinguish the two cases here. The combined wording is the intended
behavior, not a missing feature. Do not file it as a defect.

**Record:** whether the banner appeared, how long it took, and whether Open settings landed
on the right pane.

**Pass / fail:** [ ] pass  [ ] fail   Seconds: ___

Then grant the permission again, relaunch, and confirm the banner clears and Party Mode
works.

**Banner clears after granting:** [ ] pass  [ ] fail

**If it fails, look at:** `App/Views/MainWindowView.swift` (banner text, tint, and the
`openAudioPrivacySettings` URL), `App/AppModel.swift` (`audioStartFailed`, `Banner`), and
`Packages/AudioTap/Sources/AudioTap/AudioTapPermission.swift` plus `SystemAudioTap.swift`
for the failure path.

### Also: the window stays whole while the banner is up (added 2026-09-22)

Phil's bug from 2026-09-22: when the music went quiet, the sidebar went blank, the pane
header, the bulb strip and the footer disappeared, and the Party pane started half way
down under the title bar. The banner was the cause. No lights change in this sub-step
beyond whatever Party Mode is already doing, so no extra warning.

1. With the permission granted and **nothing playing**, turn Party Mode on, on the Party
   pane.
2. Wait five seconds, so the red "not hearing any audio" banner appears. (Since
   2026-09-22 pausing music that was already playing no longer raises it, so the session
   has to start in silence.)
3. With the banner up, click through all five panes, then drag the window down to its
   smallest size and back up.
4. Play some music.

**What Phil should see:** with the banner up, the window keeps every part of itself: the
five sidebar rows at the top left, the banner at the top of the pane with its message on
two lines, the pane's title and switch under it, the pane's content starting at its top,
and the bulb strip and the footer along the bottom. Hovering the banner's message shows
all of it. Step 4 makes the banner go away and nothing else moves.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `BannerView` and the frame at the end of `detail` in
`App/Views/MainWindowView.swift`, and `AppTests/MainWindowLayoutTests.swift`, which
measures this in a real window for every banner on every pane.

### Also: a pause in the music is not an error (added 2026-09-22)

Phil's ruling from 2026-09-22: the red "not hearing any audio, allow the permission"
banner used to come up every time a song ended. Now it is kept for a session that has
never heard anything, and a pause after music reads "Waiting for music" in the status
line. **WARN FIRST:** Party Mode is turned on, so the lights start following the music.
Say to Phil: "Party Mode is about to start. Your lights will follow the music." Wait for
"ready", count down 10 seconds.

1. With the permission granted and music playing, turn Party Mode on.
2. Stop the music for five seconds.
3. Play the music again.
4. Turn Party Mode off. With **nothing playing**, turn it back on and wait five seconds.

**What Phil should see:** at step 2, **no red banner**; the status line at the bottom of
the window reads "6 bulbs. Waiting for music." (the menu bar popover's top line says the
same when the menu bar icon is on). At step 3 it goes back to "6 bulbs. Listening to
system audio." At step 4 the red banner does come up, because that new session has not
heard anything yet.

**Pass / fail:** [ ] pass  [ ] fail

**If it fails, look at:** `hasHeardAudioThisSession`, `banner` and `statusLine` in
`App/AppModel.swift`, and the audio banner tests in `AppTests/AppModelTests.swift`.

---

## Step 8: Item 7, the menu bar toggle works without a restart

No lights change. No countdown needed.

**What to do:**
1. Open Settings, turn **Show Glowbeat in the menu bar** on.
2. Turn it off.
3. Turn it on again.
4. Quit Glowbeat, relaunch, and open Settings.

**What Phil should see:** the status item appears and disappears the moment the switch
changes, with no relaunch. After the relaunch in step 4, the switch is still **on**.

**Pass / fail, appears and disappears live:** [ ] pass  [ ] fail
**Pass / fail, setting survives off then on then relaunch:** [ ] pass  [ ] fail

**Why the second check matters.** Phil's menu bar is full, and macOS may evict the status
item when there is no room. The icon not being visible is a macOS decision and is
acceptable. **The setting silently turning itself off is not.** macOS writes `false` back
to the insertion binding when it evicts the item, and the Task 20 fix makes the binding
forward `true` only, so eviction can never persist as the user's preference. Settings is
the only place that can turn it off. If the switch is off after a relaunch Phil never
turned it off, that fix has regressed.

**If it fails, look at:** `App/GlowbeatApp.swift` (`menuBarInsertionBinding`),
`App/AppModel.swift` `setShowsMenuBarExtra`, and `App/Model/GlowbeatSettings.swift`
(`showsMenuBarExtra` persistence in `SettingsStore`).

---

---

## Step 9: Schedule, the wake and sleep timers and the light mode

**WARN FIRST**, twice: once for the wake and once for the sleep.

This step takes about five minutes of waiting, because the point of it is that a timer
fires on the clock rather than when a button is pressed.

**The wake.** Open the Schedule pane. Turn the Schedule switch on. Set Wake to two minutes
from now, "Light up over" to 1 min and "To" to 70%. Turn every bulb off from the strip.
Say to Phil: "In about two minutes the bulbs will come on by themselves and brighten over
a minute to 70 percent. Watch the room."

**What Phil should see:** at the wake time the bulbs come on dim, in the white the Light
card says is in force, and brighten over the minute to 70 percent. The "Next:" line under
the Sleep row has to read the wake time before it fires and the sleep time after it.

**Pass / fail:** [ ] pass  [ ] fail   Seconds late: ___

**The sleep.** Set Sleep to two minutes from now and "Dim over" to 1 min, with the bulbs
on. Say to Phil: "In about two minutes the bulbs will dim over a minute and then go out."

**What Phil should see:** the room dims for a minute and the bulbs then switch off.

**Pass / fail:** [ ] pass  [ ] fail

**Sleep wins.** Start Party Mode, then set Sleep to a minute from now. The sleep has to
stop Party Mode first and then dim. A wake set while Party Mode runs is skipped instead,
and nothing happens that day.

**Pass / fail:** [ ] pass  [ ] fail

**The Mac asleep.** Set Wake to three minutes from now, close the lid, and open it again
after the wake time has passed. The bulbs should be at the wake brightness already rather
than starting a fresh ramp.

**Pass / fail:** [ ] pass  [ ] fail

**Light mode and Night Shift.** Switch the Light card to Auto and read the caption. With
Night Shift scheduled on this Mac it should say "Following Night Shift: cool until
10:00 PM" or the warm equivalent; with no Night Shift schedule it should say "Following
the sun" and name sunrise or sunset. Compare the time it names with System Settings,
Displays, Night Shift. **Do not change anything in that pane**: Glowbeat only reads it.
Then set "Shift over" to 1 min and flip Night Shift on by hand, and watch the room move
between the two whites over about a minute.

**Pass / fail:** [ ] pass  [ ] fail   Caption read: ___________________

**If it fails, look at:** `App/Schedule/ScheduleEngine.swift` (the thirty second poll and
the catch up window), `App/Schedule/LightModeEngine.swift` (Auto and the shift),
`App/Schedule/NightShiftClient.swift` (the only thing that reads CoreBrightness, and the
one part of the feature no test can exercise), `App/Views/SchedulePanelView.swift`.


## Step 10: Colors, one color on the whole room

**WARN FIRST.** Say to Phil: "The bulbs are going to change color three times. Watch the
room."

**Pick a color.** Open the Colors pane. Click **Golden hour** in the Sky group.

**What Phil should see:** every reachable bulb comes on at once and goes a deep amber
gold, at 70 percent. The swatch takes an amber ring, its name turns amber, and the sidebar
line under Colors reads "Golden hour, 70%".

**Pass / fail:** [ ] pass  [ ] fail

**Drag the brightness.** Drag the Brightness slider at the top of the pane from end to
end, slowly, and let go.

**What Phil should see:** the room follows the drag, without stuttering or falling
behind, and holds wherever it is let go. The readout at the right and the sidebar line
both follow. **The slider must have no tick marks under it**, and neither must any other
slider in the app: check Travel on the Party pane with Wave chosen, all three sliders on
the Schedule pane, and "Most updates per bulb, per second" in Settings.

**Pass / fail:** [ ] pass  [ ] fail   Ticks seen anywhere: [ ] no  [ ] yes, where: ______

**Daylight matches the Schedule pane.** Click **Daylight** in the Whites group and look at
the room. Then open the Schedule pane, set the Light card to **Daylight**, and look again.

**What Phil should see:** the same white both times. They are the same 6000 K by
construction, so a visible difference is a bug.

**Pass / fail:** [ ] pass  [ ] fail

**It stays, and it lets go.** Leave the room on a color for a minute and confirm nothing
repaints it. Then start Party Mode: the room goes to the music and the Colors line drops
to "Off" while the swatch stays ringed. Switch Party Mode off, then reach for a bulb's
brightness in the strip: it moves and nothing argues with it.

**Pass / fail:** [ ] pass  [ ] fail

**The same colors from the menu bar.** Turn the menu bar item on if it is off (Settings,
General), then click it. Between the All bulbs block and Party Mode there is a **Colors**
block: four rows of small swatches, the same 26 colors in the same order as the pane, with
the applied color named on the right of the header.

**What Phil should see:** hovering a swatch lifts it and names it (a white also gives its
temperature, "Warm, 3000 K"). Clicking one lights the room at once, exactly as the pane
does, and that swatch takes the amber ring while every other ring clears. The header
readout changes to the color's name, and to "Off" the moment Party Mode or a scene takes
the room. Nothing in the grid should be hard to hit: every swatch is clickable over a box
larger than the color it draws, and no two boxes touch.

**Pass / fail:** [ ] pass  [ ] fail

**The popover's brightness slider has two jobs.** With no color applied, drag it: it is
the plain All bulbs brightness it has always been. Now click a swatch and watch the
slider.

**What Phil should see:** the slider jumps to the Colors brightness (70% on a fresh
install) because that is the brightness the color was just sent at. Drag it now and the
room follows on release, the Colors pane's own Brightness slider moves to match, and the
number survives a relaunch. Dragged to the bottom it settles at 1%, not 0, because zero is
a bulb that is off. Start Party Mode and the slider goes back to being the All bulbs
command. **No tick marks under it.**

**Pass / fail:** [ ] pass  [ ] fail   The jump to 70% is: [ ] fine  [ ] wrong, it should
keep my number

**If it fails, look at:** `App/Model/StillColor.swift` (the catalog and the Kelvin and RGB
values), `AppModel.applyStillColor` and `AppModel.setStillBrightness` (the order of the
three commands, the 150 ms rate limit and the exclusivity rules),
`App/Views/ColorsPanelView.swift` and `App/Views/StillColorSwatch.swift` (the pane's
grid), `App/Views/MenuBarColorsSection.swift` (the popover's grid and its metrics),
`App/Views/MenuBarContentView.swift` (`brightnessTarget`, which is what decides which of
the two brightnesses the popover slider is moving),
`App/Views/PartyPanelView.swift` (`LabeledValueSlider.snapped`, which is where the tick
marks used to come from).


## Results

| # | Item | Result | Notes |
|---|---|---|---|
| 0 | Build is signed with an Apple Development identity, hardened runtime, both usage strings | pass or fail | |
| 0 | Local Network is on for Glowbeat in Privacy and Security | pass or fail | |
| 1 | Discovery finds 6 bulbs within 3 s of launch | pass or fail | seconds observed |
| 2 | Per bulb and All controls change the real bulbs, readback matches | pass or fail | |
| 3 | Party Mode, Pulse follows the beat | pass or fail | |
| 3 | Party Mode, Spread splits across bulbs | pass or fail | |
| 3 | The Bulbs row shows only on Spread, and two bulbs on High flicker on the hats | pass or fail | |
| 3 | A chosen band follows its bulb through a reorder and a relaunch | pass or fail | |
| 3 | A fresh install reads Punchy on the Feel row | pass or fail | |
| 3 | Party Mode, Wave travels bulb to bulb | pass or fail | |
| 3 | Travel shows only on Wave, crawls at 1 bulb/s and races at 15 | pass or fail | |
| 3 | Party Mode, Glow follows volume | pass or fail | |
| 3 | Pulse holds each color for four beats and fades to the next; every beat still flashes | pass or fail | |
| 3 | Spread's Bass bulbs reach full brightness, told apart by a deeper shade | pass or fail | |
| 3 | Confetti: no two neighbors ever share a color, on all four effects, live, remembered | pass or fail | palette |
| 3 | Party gate quiets and releases the room | pass or fail | |
| 3 | The gate closing glides the room down rather than dropping it in one step | pass or fail | |
| 3 | Advanced starts collapsed, opens, and remembers that across a relaunch | pass or fail | |
| 3 | Each Feel sets all four sliders to its own numbers and changes the room | pass or fail | |
| 3 | Dragging a slider drops the Feel row to Custom, and tapping the feel puts it back | pass or fail | |
| 3 | A feel survives a relaunch, and never moves the marker, the effect or the palette | pass or fail | |
| 3 | The restyled panel reads correctly in both Light and Dark Appearance | pass or fail | |
| 3 | Darkest and Brightest set the range, live, and never meet | pass or fail | |
| 3 | Snap ramps hits in on Pulse, Wave and Spread, and is instant at the top | pass or fail | |
| 3 | Fade reads in seconds up to 5.0 s and changes how long the room takes to settle | pass or fail | |
| 3 | Scenes: Breathe, Color flow, Candle, Static all read as intended | pass or fail | |
| 3 | Static's Single color switch puts one color on every bulb | pass or fail | |
| 3 | Sunset runs its timeline and ends with the bulbs off | pass or fail | |
| 3 | Scenes and Party Mode are mutually exclusive, nothing runs on launch | pass or fail | |
| 3 | Party Mode and a scene bring a dimmed room up to full brightness first | pass or fail | |
| 3 | Ten bulbs keep up; Settings reads "10 (6 with 10 bulbs)" | pass or fail | readout, feel |
| 3 | Stopping on a held back Night ends on the warm white, not the dim base | pass or fail | |
| 3 | Stopping with nothing held back settles on the dim base | pass or fail | |
| 3 | A color picked mid session is what the room ends on | pass or fail | |
| 4 | The marker visibly changes how often bulbs react, live, at both ends | pass or fail | |
| 4 | The toolbar gear opens Settings | pass or fail | |
| 4 | Both sections collapse, the window goes short, and the choice survives a relaunch | pass or fail | |
| 5 | Phone brightness change pauses Party Mode within 2 s (about 2.5 s with ten bulbs) | pass or fail | seconds observed |
| 5 | Phone color only change pauses after three polls, about 2 to 3 s (3.3 to 5 with ten) | pass or fail | seconds observed |
| 5 | Ten minutes of busy Party Mode with no phone never pauses | pass or fail | minutes, effect |
| 5 | Resume restarts Party Mode | pass or fail | |
| 5 | Phone scene is detected as an external change | pass, fail or known limitation | |
| 6 | Audio denied path shows the banner and Open settings lands right | pass or fail | seconds observed |
| 6 | Banner clears once the permission is granted again | pass or fail | |
| 6 | A pause after music shows no banner and the status line says Waiting for music | pass or fail | |
| 6 | A new session started in silence still shows the red banner | pass or fail | |
| 7 | Menu bar toggle shows and hides without restart | pass or fail | |
| 7 | Menu bar setting survives off, on, and a relaunch | pass or fail | |
| 10 | Colors: picking a swatch lights the room and the sidebar names it | pass or fail | |
| 10 | The brightness slider follows a drag without stuttering | pass or fail | |
| 10 | No slider anywhere in the app draws tick marks | pass or fail | where, if any |
| 10 | Colors' Daylight and the Schedule Light card's Daylight are the same white | pass or fail | |
| 10 | A still color stays until Party Mode, a scene or the Light mode takes the room | pass or fail | |
| 10 | The menu bar popover shows the same 26 colors and picking one lights the room | pass or fail | |
| 10 | The popover's brightness slider drives the still color once one is applied | pass or fail | |

## Known limitations

Carry these forward before the run. Add anything the run turns up.

- **Color well settle window is time based, not acknowledgment based.** After a control
  is touched it ignores polled readings for a fixed 3 seconds (`ControlSettle.duration` in
  `App/Views/BulbListView.swift`). A one shot command is repeated three times a second
  apart and the reply can land a second after that, so a shorter window lets a stale
  reading snap the control back. The cost is that a real phone change made inside that
  3 second window will not show in the control until the next poll after it closes. There
  is no acknowledgment to key it on, because Govee's LAN protocol does not send one.
- **"Not hearing any audio" cannot distinguish denied from silent on this Mac.**
  `SystemOutputVolume.current()` returns nil on Phil's output device, so the banner covers
  both cases in one message by design. See Step 7. Since 2026-09-22 it only shows for a
  Party session that has heard nothing; once a session has heard music, silence reads
  "Waiting for music". The cost: a permission revoked in the middle of a session also
  reads "Waiting for music" until Party Mode is switched off and on again.
- **A status item evicted from a full menu bar is invisible but still enabled.** macOS
  decides this, not Glowbeat. The setting stays on. See Step 8.
- **Party Mode and scenes leave the bulbs at full brightness when they stop.** They set
  it as they start (their dimming is in the colors) and never put the old brightness
  back, because the only record of it is a status report that may be a minute stale.
- **A phone brightness change in the first seconds of a session is not caught.** Party
  Mode's own full brightness is repeated a second and two seconds after it starts, which
  puts the phone's value back, and a bulb's brightness is only judged once it has
  reported the full brightness at least once.
- **A room of more than thirty bulbs goes over the send budget.** Two updates a second
  per bulb is the floor, because anything slower no longer reads as motion.
- `<add any found during the run, one line each, or "none">`

## Defects found and fixed

One defect, one failing test, one commit. Rerun only the affected item.

| Item | What happened | Test that reproduces it | Commit |
|---|---|---|---|
| | | | |
