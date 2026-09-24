# Wake/sleep timers, Daylight/Night modes, and Auto (Night Shift) research

Date 2026-09-14. Machine under test: MacBook Pro, macOS 26.6.2 (build 25G83), Darwin 25.6.0, arm64 (T6000), Swift 6.2.4.
All local results came from throwaway probes in the session scratchpad. Nothing in the repo was changed, no bulb was touched, Glowbeat was not run. Night Shift settings were briefly driven through one scheduled transition to measure the ramp, then restored; the status reads back byte for byte identical to the pre test baseline.

**Bottom line.** The private API works on macOS 26 and gives more than expected: it also hands over live sunrise/sunset and the live ramp value, with no permission prompt. Two hard constraints: the **App Sandbox blocks it completely** (Glowbeat is not sandboxed, so this is fine, but it can never be sandboxed), and a **wake timer cannot turn on bulbs whose smart switch has cut power**.

---

## A. Reading Night Shift from a third party app

### A1. Present and usable on macOS 26. Confidence: high (measured here).

`dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)` succeeds, `objc_getClass("CBBlueLightClient")` resolves, `+supportsBlueLightReduction` returns true. 28 instance methods are present, including all of `getBlueLightStatus:`, `getStrength:`, `getCCT:`, `getCCTRange:`, `getDefaultCCTRange:`, `getWarningCCT:`, `getWarningStrength:`, `supported`, `setStatusNotificationBlock:`, `enableNotifications`, `disableNotifications`, `suspendNotifications:force:`, `parseStatusDictionary:intoStruct:`, plus the setters (`setEnabled:`, `setMode:`, `setSchedule:`, `setStrength:commit:`, `setStrength:withPeriod:commit:`, `setCCT:withPeriod:commit:`).

**Packaging trap:** that path is a **broken symlink on disk** (the binary lives only in the dyld shared cache). `dlopen` on it succeeds anyway. Never gate on a file existence check.

### A2. Status struct layout. Confidence: high.

The live ObjC type encoding on this Mac, `^{?=BBBi{?={?=ii}{?=ii}}QB}`, matches Shifty's published header exactly:
https://github.com/thompsonate/Shifty/blob/master/Shifty/CBBlueLightClient.h

```objc
typedef struct { int hour; int minute; } Time;
typedef struct { Time fromTime; Time toTime; } Schedule;
typedef struct {
    BOOL active;                     // offset 0
    BOOL enabled;                    // offset 1
    BOOL sunSchedulePermitted;       // offset 2
    int mode;                        // offset 4
    Schedule schedule;               // offset 8  (fromH, fromM, toH, toM as int32)
    unsigned long long disableFlags; // offset 24
    BOOL available;                  // offset 32
} Status;
```

**Over-allocate the buffer.** Apple added the 7th field (`available`) in 10.14.6/10.15, and apps compiled against the 6-field struct got stack corruption and crashed on launch for every user (https://github.com/thompsonate/Shifty/issues/86, fixed in https://github.com/thompsonate/Shifty/pull/87). Pass a 64 byte zeroed buffer and decode by offset, not a Swift struct whose layout Swift does not guarantee to be C compatible.

`mode`: **0 = no schedule, 1 = sunset to sunrise, 2 = custom schedule**, confirmed by the named enum in https://github.com/srirangav/displayutil/blob/main/CBBlueLightClient.h and by Shifty's Swift layer. `disableFlags` was 0 in every state produced and no source documents its bits. Confidence on mode: high. On disableFlags: **unknown, do not rely on it**.

### A3. Raw output read on this Mac. Confidence: high (verbatim).

```
[t0] getBlueLightStatus: returned true
[t0] raw first 48 bytes:
  01 00 01 00 00 00 00 00 16 00 00 00 00 00 00 00
  07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
[t0] active=1 enabled=0 sunSchedulePermitted=1 mode=0
     schedule=22:0 -> 7:0 disableFlags=0 available=1
[t0] getStrength: = 1.0
supportsBlueLightReduction = true;  supported = true
getCCTRange: / getDefaultCCTRange: -> (2700.00, 6000.00, 4100.00)
getCCT: -> 2700.0000;  getWarningCCT: -> 4100.0000;  getWarningStrength: -> 0.5000
```

### A4. **Use `enabled`, never `active`.** Confidence: high.

Shifty's shipping code reads `blueLightStatus.enabled` as `isNightShiftEnabled`. On this Mac `enabled = 0` (off) while `active = 1`. Comparing the struct against the OS status dictionary (`AutoBlueReductionEnabled = 1`, `BlueReductionEnabled = 0`) indicates field 1 is really `AutoBlueReductionEnabled`, not "currently tinted". Confidence on that naming: moderate. Confidence that `active` is the wrong flag to read: high.

### A5. **`getStrength:` does not ramp. It is the configured slider.** Confidence: high (measured twice).

A real scheduled transition was driven (custom schedule starting one minute out) and sampled at 1 Hz:

```
04:45:01  getStrength=1.00000  getCCT=2700.00  factor=0.00000  enabled=0
04:45:02  getStrength=1.00000  getCCT=2700.00  factor=0.01553  enabled=1   <- edge
04:45:22  getStrength=1.00000  getCCT=2700.00  factor=0.18227  enabled=1
04:46:05  getStrength=1.00000  getCCT=2700.00  factor=0.53226  enabled=1
04:47:02  getStrength=1.00000  getCCT=2700.00  factor=1.00000  enabled=1   <- +120 s
```

`enabled` flips instantly at the edge; `getStrength:` and `getCCT:` never move. Second, independent confirmation: with Night Shift fully off and the screen untinted, `getStrength:` still returns 1.0 and `getCCT:` still returns 2700 (the floor of the 2700 to 6000 range). Both getters report the configured setting regardless of what is applied.

### A5b. **The live ramp lives on `BrightnessSystemClient`.** Confidence: high (confirmed read only here).

```
--- BlueLightReductionFactor ---
{ BlueLightReductionFactorFadePeriod = "-1"; BlueLightReductionFactorValue = 0; }
--- BlueLightReductionTransitionLength ---
120
```

`BlueLightReductionFactorValue` is **0 while Night Shift is off**, where `getStrength:` says 1.0. That is the tell: this key is the live applied fraction. It ramps 0 to 1 **linearly over exactly 120 s**, matching `BlueLightReductionTransitionLength = 120`. Other readable keys: `BlueLightReductionCCTRange` = (2700, 4100, 6000), `BlueLightReductionCCTTargetValue` = 2700, `BlueLightReductionTransitionRate` = 2.

**Asymmetry:** a manual toggle snaps the factor 0 to 1 instantly with no ramp. Only the scheduled edge ramps.

**Recommendation for Auto mode: interpolate locally.** Read `enabled` for the state and compute Glowbeat's own ramp. It is one fewer private key to depend on, and 120 s is far too fast for a room light; the ramp length should be Phil's to choose. Poll `BlueLightReductionFactorValue` at 1 to 4 Hz only if he explicitly wants the bulbs locked to the screen.

### A6. `setStatusNotificationBlock:` works, with three caveats. Confidence: high.

Signature `v24@0:8@?16`, a zero argument `void (^)(void)`, so the handler must re read status itself. Measured behavior:

- Fires once at the scheduled edge and **not during the 120 s ramp**, so it cannot drive a fade.
- Fires on a **background thread**. Marshal to the main actor.
- Fires **per mutation, not per logical change** (one restore of mode + schedule + enabled fired three times). Debounce, and guard against your own writes echoing back.

### A7. Hardened runtime is fine. **The App Sandbox is not.** Confidence: high (both measured).

Re signed with Glowbeat's exact entitlements and `--options runtime` (verified `flags=0x10000(runtime)`, real Team ID): identical output. Also verified working under `-o runtime,library`, so **library validation does not matter** and `com.apple.security.cs.disable-library-validation` is not needed. CoreBrightness is an Apple platform binary. No entitlement, no TCC prompt, no root.

Under the **App Sandbox it fails completely**: `dlopen` and the class lookup still succeed, but `getBlueLightStatus:`, `getStrength:` and `getCCT:` all return **false** and leave the buffer untouched. The system log names the cause:

```
launchd: denied lookup: name = com.apple.backlightd, requestor = SBProbe, error = 159: Sandbox restriction
```

CoreBrightness proxies to the `com.apple.backlightd` XPC service and the sandbox denies the mach lookup. **Trap: `supportsBlueLightReduction` still returns true under the sandbox**, so it is useless as an availability check. Gate on the `BOOL` return of `getBlueLightStatus:`.

`App/Glowbeat.entitlements` holds only `com.apple.security.device.audio-input`, with **no** `com.apple.security.app-sandbox` key, and `project.yml` sets `ENABLE_HARDENED_RUNTIME: YES`. That is exactly the configuration tested, so this works for Glowbeat as it ships. It also means this feature permanently rules out the Mac App Store, which Developer ID distribution already did.

Notarization is not a barrier: Shifty 1.2 ships Developer ID signed, hardened runtime, notarized and stapled while using this API.

### A8. Breakage risk. Confidence: moderate.

No open or closed issue in Shifty, smudge/nightlight, or a GitHub wide search since 2024-09 reports `CBBlueLightClient` breaking on macOS 15 or 26, and new 2026 projects still call it. But Shifty is unmaintained (last release 2021; its "macOS 26 Support" PR #130 was closed unmerged, https://github.com/thompsonate/Shifty/pull/130). This is a private API and can vanish in any update. Wrap every call in a capability check (`responds(to:)` per selector **plus** the BOOL return) and fall back to B.

---

## B. Auto without the private status API

### B1. Sunrise and sunset come free, with no permission prompt. Confidence: high (measured).

`BrightnessSystemClient.copyPropertyForKey("BlueLightSunSchedule")` returned, verbatim:

```
{ isDaylight = 0;
  nextSunrise     = "2026-09-16 13:13:59 +0000";   nextSunset      = "2026-09-17 01:30:07 +0000";
  previousSunrise = "2026-09-14 13:12:04 +0000";   previousSunset  = "2026-09-15 01:33:28 +0000";
  sunrise         = "2026-09-15 13:13:01 +0000";   sunset          = "2026-09-16 01:31:48 +0000"; }
```

`previousSunset` is 19:33 MDT and `sunrise` is 07:13 MDT, correct for Phil's city on 2026-09-14. `registerNotificationBlock:forProperties:` is available for change callbacks. Same sandbox caveat as A7.

### B2. Fallbacks, in order. Confidence: high.

1. `BlueLightSunSchedule` above.
2. Manual "sunset / sunrise time" pair in Settings, seeded from (1) when available.
3. CoreLocation, only if pushed to it.

**Skip CoreLocation.** It needs `NSLocationWhenInUseUsageDescription` added to `App/Info.plist` (currently absent) and shows a system prompt. Adding a location prompt to a lamp controller, on top of Local Network and audio capture, reads as creepy for near zero gain. Sunrise and sunset can also be computed offline from a latitude and longitude the user types, with no framework at all.

**There is no public API for Night Shift state.** Nothing in AppKit, CoreGraphics or IOKit exposes it, and there is no AppleScript dictionary for it. The plist route (`/var/root/Library/Preferences/com.apple.CoreBrightness.plist`, keyed `CBUser-<GeneratedUID>` then `CBBlueReductionStatus`) needs **root**: confirmed Permission denied as a normal user here, and `defaults read com.apple.CoreBrightness` reports the domain does not exist. It is also cached by corebrightnessd and gives no notifications, so it is strictly worse than the framework.

---

## C. Timers while the Mac sleeps

### C1. `DispatchSourceTimer` with `.now()` loses all sleep time. Confidence: high (measured here).

```
boottime                 : 2026-08-27 05:56:01 +0000
wall clock since boot    : 1637537.4 s
ProcessInfo.systemUptime : 1572925.8 s
CLOCK_UPTIME_RAW         : 1572925.0 s   (excludes sleep)
wall MINUS uptime_raw    : 64612.4 s     <- 17.9 hours this Mac spent asleep
DispatchTime.now()       : 1572925 s     <- matches the uptime clock exactly
```

A timer armed for "in 9 hours" with `.now() + 9h` across a night of sleep fires 9 hours of *awake* time later, which can be days. `App/Party/TickSource.swift` uses exactly that form, correct for a 10 Hz party tick and wrong for a wake alarm. `SceneClock` in `Packages/Effects/Sources/Effects/LightScene.swift` runs on `ProcessInfo.processInfo.systemUptime`, same clock, same caveat.

Preferred fix: **do not use a long timer at all.** Keep a short repeating check (every 30 to 60 s) comparing `Date()` against the schedule. If a long timer is wanted, use `schedule(wallDeadline:)` with `DispatchWallTime`, which is wall clock based. `NSTimer`/`CFRunLoopTimer` are also wall clock based and an overdue repeating timer fires once immediately on wake. **None of them fire while the Mac is actually asleep.**

### C2. `NSWorkspace.didWakeNotification` fires on wake, and Glowbeat already uses it. Confidence: high.

`NSWorkspaceDidWakeNotification`, `NSWorkspaceWillSleepNotification` and `NSWorkspaceScreensDidWakeNotification` all confirmed present. `App/AppModel.swift:312` already registers for `didWakeNotification` to restart the LAN socket, so the observer wiring and teardown exist in `startNetworkWatchers()` / `stopNetworkWatchers()`.

### C3. Catch up pattern.

Never replay missed events. On each of launch, `didWakeNotification`, and every periodic tick, ask one question: **given the wall clock right now, what state should the lights be in?** Then apply it once, idempotently.

- Between wake time and sleep time: on, at the mode's target level.
- Inside a ramp window: jump straight to the interpolated point, do not restart the ramp.
- Past the sleep time: off.
- Keep a "last applied state" value so a wake plus a network path change do not double send.

This also covers the lid being shut through a whole ramp: the Mac wakes at 08:10 into a 07:00 to 07:30 ramp that already ended and simply applies the finished daylight state.

### C4. Waking the Mac from Glowbeat needs root. Confidence: high (measured).

- `pmset schedule wake ...` as Phil's user: `pmset: This operation must be run as root`.
- `IOPMSchedulePowerEvent(date, "...", kIOPMAutoWake)` returned `-536870207` (`kIOReturnNotPrivileged`). Nothing was scheduled; `pmset -g sched` was unchanged before and after.

The only routes are a privileged helper installed with `SMAppService` (an authorization prompt plus a second signed and notarized binary) or one hand run `sudo pmset repeat wake`. For a lamp feature, recommend neither. Say in the UI that the Mac must be awake, and that the schedule otherwise applies on next wake.

---

## D. Bulb side

### D1. `colorwc` with `colorTemInKelvin` is the white command, already implemented. Confidence: high.

`LANMessage.colorwc(kelvin:)` at `Packages/GoveeLAN/Sources/GoveeLAN/LANMessage.swift:180`, exposed as `BulbController.setColorTemperature(kelvin:bulbs:)`. It puts `r,g,b = 0` on the wire. `colorTemInKelvin = 0` means "use the RGB instead"; non zero puts the bulb in white mode and the RGB is ignored (the private protocol research notes:157`). The bulb echoes the zeroed color back in `devStatus`, which is why `setColorTemperature` already records black into the send history so external change detection does not read it as a phone takeover.

### D2. **Kelvin range: the protocol says 2000 to 9000, the H6004 does not.** Confidence: high on protocol, moderate to high on hardware.

- Govee's LAN API doc: "The range is 2000-9000." https://gist.github.com/mtwilliams5/08ae4782063b57a9b430069044f443f6
- H6004 retail spec: **2700 K to 6500 K**. https://lightbulbben.com/h6004 ; Home Depot lists the 4 pack (B6004AC3) as "2700-6500K RGBWW Smart LED Bulb".
- This repo's own decompile work agrees on the floor: "**H6004 floors at 2700 K** (H6005 reaches 2000 K)" (`docs/research/govee-lan-and-mac-audio-research.md:165`).
- Convenient: CoreBrightness's own CCT range here is 2700 to 6000, so the Mac's warm end and the bulb's warm end are the same number.
- **Out of range values are silently ignored.** home-assistant/core#182244 documents the same bug class: below the hardware floor the light "keeps its previous value, returns no error, and reports the old value on the next status poll." https://github.com/home-assistant/core/issues/182244

Action: clamp to **2700 to 6500 K** as a named constant. There is no error to catch, so an unclamped value is an invisible no op. Suggested anchors: Night 2700 K, Daylight 5000 to 6500 K, subject to a hardware pass.

### D3. Ramping is fine, but nothing streams Kelvin today. Confidence: high.

`StreamRateLimiter` supports 2 to 10 sends per second per bulb and Party Mode ships at 10, but `BulbController.streamColor` and `sendStreamed` are **RGB only**. There is no streamed Kelvin or streamed brightness path. `setColorTemperature` and `setBrightness` go through `sendOneShot`, which sends **three times, one second apart** (UDP has no retries), and because Kelvin and RGB share the single `.color` command kind, each new step cancels the previous step's pending retries.

A ramp does not need 10 Hz. A 30 minute dim up has roughly 40 to 100 perceptible steps, so one step every 10 to 30 s is plenty and the triple send becomes a reliability feature rather than a cost. Build the ramp on `setColorTemperature` plus `setBrightness` at a low step rate. `colorwc` is itself a 0.3 to 1 s fade on this hardware (`docs/research/govee-lan-and-mac-audio-research.md:30`), which smooths the steps for free.

### D4. **A wake timer cannot turn on bulbs that have no power.** Confidence: high.

`handoff.md` records that the bulb string sits on a scheduled smart switch that cuts power at night and the bulbs go offline. A `turn on` packet to an unpowered bulb reaches nothing: it is not on the network, UDP is fire and forget, and there is no error. Two consequences:

1. The morning wake timer only works if the smart switch restores power **before** Glowbeat's wake time. Otherwise the feature does nothing on exactly the mornings it was built for.
2. The bulb **restores its last state on mains power on** (`govee-lan-and-mac-audio-research.md`, trap 4). If the night ramp ends at deep warm 5 percent, that is what the room gets when the switch fires at 06:00, before Glowbeat says anything.

The wake routine must not assume the bulbs are reachable at ramp start: retry discovery for a grace window and, on first contact, jump to the correct interpolated point. Surface this in one plain UI sentence so Phil is not debugging a dark room.

---

## E. What a ramp routine can reuse from SceneEngine / SceneCoordinator

Reusable as is:

- **The serial send chain** (`enqueueCommand`, `App/Scenes/SceneEngine.swift`): one `Task` chained on the previous, so an earlier tick can never overtake a later one. Exactly what a ramp needs so the final "off" is the last thing a bulb hears.
- **`SunsetScene`'s finish semantics** (`Packages/Effects/Sources/Effects/SunsetScene.swift`): `progress: Double?`, `isFinished`, and `SceneEngine.finish()` which flushes, sends `turn(false)`, and returns the control to off. A "dim down then off" night ramp is the same shape.
- **The progress bar plumbing** (`onProgressChange` to `SceneCoordinator.progress`), already rendered for Sunset, so a ramp in progress gets a bar for free.
- **`ColorDeduper`**: a slow ramp holds a value for many ticks, and the deduper already suppresses repeats so a holding ramp costs no traffic.
- **The mutual exclusion rule** in `SceneCoordinator`. A scheduled ramp is a third claimant on the bulbs and needs the same arbitration, plus a rule for a timer firing while Party Mode runs. Suggested: the timer does not stomp Party Mode, it logs and skips. Phil's call.
- **`ExternalChangeDetector` and the send history**: ramp commands must go through `BulbController` or the app reads its own ramp as a phone takeover.
- **`TickSource`** as a test seam, so a 30 minute ramp is provable in milliseconds the way the injected `clock` already proves a 20 minute Sunset.

Does **not** carry over:

- `SunsetScene` ramps by scaling **RGB** (`color.scaled(by:)`), never the `brightness` command and never Kelvin. It is a color fade that looks like dimming. A real Daylight/Night ramp wants true brightness (0 to 100) plus `colorwc` Kelvin, a different output type than `LightScene`'s `[RGB]`. Either widen the scene output or build the ramp as its own small engine alongside `SceneEngine`.
- `SceneClock` advances on `systemUptime`, which stops during sleep (C1). A scheduled ramp must run off `Date()`.

---

## Open questions

1. The H6004's real Kelvin ceiling. Retail says 6500. Needs a bulb probe: send 6500, 7000, 8000 and read back `devStatus`.
2. `disableFlags` bit values: unknown, no documentation found anywhere. Do not depend on it.
