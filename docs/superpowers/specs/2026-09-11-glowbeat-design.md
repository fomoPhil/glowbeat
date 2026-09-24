# Glowbeat: design spec

Date: 2026-09-11. Status: approved by Phil in conversation, pending written review.

## 1. What it is

A native macOS app that controls Govee H6004 Wi-Fi bulbs on the local network and adds a "Party Mode" that makes the bulbs react to whatever audio the Mac is playing. Govee ships this for Windows and (mic-based) iOS, not for Mac.

Working name: Glowbeat. Bundle id, icon, and final name are decided at packaging time.

## 2. Verified facts the design rests on

All verified on 2026-09-11 against Phil's six H6004 bulbs (firmware wifiVersionSoft 1.01.27) from a Mac on the same Wi-Fi.

| Fact | Evidence |
|---|---|
| Bulbs answer the Govee LAN scan on UDP multicast 239.255.255.250:4001 (reply to port 4002) once "LAN Control" is toggled on per bulb in Govee Home | `docs/research/probes/lanscan2.py` |
| Unicast JSON commands to bulb-ip:4003 work with no login or cloud: `turn`, `brightness`, `colorwc`, `devStatus` | `docs/research/probes/ctl.py` |
| `colorwc` at 8 to 10 sends per second renders as a smooth color sweep; alternating two colors at 4 per second renders as a quick smooth fade between them | Phil observed, `docs/research/probes/cwc2.py` |
| The strip-style realtime stream (`razer` / `0xBB` frames) is ignored by H6004 | `docs/research/probes/razer.py`, `rt2.py` |
| The Bluetooth-relay command (`ptReal` with `0x33 05 05` music frames) is ignored by H6004 over LAN | `docs/research/probes/music.py`, `rt2.py` |
| `devStatus` reports the state of the last normal command (onOff, brightness, color, colorTemInKelvin) | `ctl.py` output |
| Govee's Windows app computes music mode entirely on the PC (WASAPI loopback, band-pass 20 Hz to 5 kHz order 10, 20-frame rolling energy window, threshold 0.5, 0.1 s per-band debounce, five bands) | the private protocol research notes |
| macOS system-audio capture with no drivers: CoreAudio process tap plus private aggregate device, needs `NSAudioCaptureUsageDescription`, no Screen Recording permission | `docs/research/govee-lan-and-mac-audio-research.md` section 5 |

Consequence: Party Mode uses `colorwc` at up to 8 updates per second per bulb. Every change fades, so effects are designed as pulses and sweeps, not strobes.

## 3. Decisions made with Phil

| Decision | Choice |
|---|---|
| Transport | Wi-Fi LAN only (route A). Bluetooth is a possible later swap of the transport layer, not in v1. |
| App form | Regular window app. Menu bar icon is an optional setting, default off. |
| Audience | Phil first, then other people. Personal Apple team. Direct download, Developer ID signed and notarized. Not App Store in v1. |
| Party Mode effects | Three, in a picker: Pulse (all bulbs in sync), Spread (bulbs assigned to bass / mid / high bands), Wave (color travels bulb to bulb on the beat). |
| Phone takeover | If the Govee phone app changes a bulb while Party Mode runs, Party Mode pauses and says so. |
| Monetization | Free in v1. |

## 4. Architecture

One Xcode project, one app target, three local Swift packages the app depends on. Each package is testable on its own and has no knowledge of the others.

```
Glowbeat.xcodeproj
  Glowbeat/            SwiftUI app: windows, menu bar, settings, wiring
  Packages/
    GoveeLAN/          discovery + control + status polling
    AudioTap/          system audio capture -> band energies
    Effects/           beat detection + the three effects
```

### 4.1 GoveeLAN

Purpose: talk to bulbs. Depends only on Foundation and Network.

Public surface:

- `Bulb`: id (the `device` MAC string from scan), sku, ip, firmware strings, last known `BulbState` (onOff, brightness 0-100, rgb, kelvin), `isReachable`, `lastSeen`.
- `BulbDiscovery`: sends the multicast scan, collects replies on UDP 4002, publishes the bulb list. Rescan on demand and automatically every 60 s. A bulb missing for 3 scans is marked unreachable, never deleted.
- `BulbController`: `turn(on:)`, `setBrightness(_:)`, `setColor(rgb:)`, `setColorTemperature(kelvin:)`, `requestStatus()` for one bulb or a set of bulbs.
  - One-shot commands (from the UI) are sent 3 times, 1 s apart, matching Govee's desktop app, because UDP is lossy.
  - Streamed commands (from Party Mode) are sent once, coalesced: at most 8 per second per bulb, latest value wins.
- `StatusPoller`: sends `devStatus` to each bulb on an interval (1 s while Party Mode runs, 10 s otherwise), publishes `BulbState` updates.
- Packet encoding lives in `LANMessage` (Codable structs), one function per command, no side effects. Unit-tested byte for byte against the JSON in the private protocol research notes.
- `FakeBulb`: a test-only UDP responder that answers scan and devStatus and records commands, so every GoveeLAN test runs without hardware.

Error handling: UDP has no errors to speak of. Reachability is inferred from scan and status replies. Send failures from the socket are logged and retried on the next tick, never surfaced as alerts.

### 4.2 AudioTap

Purpose: turn "whatever the Mac is playing" into numbers. Depends on CoreAudio and Accelerate.

Public surface:

- `SystemAudioTap`: `start()`, `stop()`, and an `AsyncStream<AudioFrame>`.
- `AudioFrame`: timestamp, overall RMS 0-1, and five band energies 0-1 (sub-bass, bass, low-mid, mid, high-mid, matching Govee's five bands), delivered 50 times per second.
- `AudioTapPermission`: `.unknown`, `.granted`, `.deniedOrSilent`. Since macOS returns success even when denied, denial is inferred: 3 seconds of all-zero buffers while the system output volume is above zero.

Implementation: `CATapDescription(stereoGlobalTapButExcludeProcesses: [self])`, private aggregate device on the built-in output, `AudioDeviceCreateIOProcIDWithBlock`. 1024-point vDSP FFT per callback, band sums, then a short exponential smoothing. The Info.plist must carry `NSAudioCaptureUsageDescription` (verified with `plutil -p`), and the app must be code signed or the permission grant never sticks.

Testing: the FFT and band code take plain float buffers, so they are unit-tested with synthetic tones (a 60 Hz sine must land in sub-bass, a 3 kHz sine in high-mid). The tap itself is exercised by a manual smoke test, not unit tests.

### 4.3 Effects

Purpose: from band energies to a color per bulb. Pure Swift, no dependencies.

Public surface:

- `BeatDetector`: input `AudioFrame`, output `BeatEvent` per band. Port of Govee's algorithm: 20-frame rolling energy window per band, beat when current energy exceeds 0.5 times the window mean plus a sensitivity offset, 0.1 s debounce per band. Sensitivity 0-1 scales the threshold.
- `Effect` protocol: `func tick(beats: [BeatEvent], frame: AudioFrame, bulbCount: Int, palette: Palette, time: TimeInterval) -> [RGB]`. Called 8 times per second.
- Effects:
  - `PulseEffect`: all bulbs same color. Beat on bass picks the next palette color at full brightness, then the color decays toward the palette's dim base over about 0.5 s (the bulb's own fade makes this look smooth).
  - `SpreadEffect`: bulbs are dealt round-robin to bass, mid, high. A beat in a band flashes that band's bulbs. Quiet bulbs sit at the dim base.
  - `WaveEffect`: each bass beat pushes a new palette color into bulb 1; on every tick colors shift one bulb along, so the color travels across the room.
- `Palette`: named list of 4 to 6 colors plus a dim base color. Ships with 5 palettes (Party, Sunset, Ocean, Neon, Warm White pulse). Custom palettes are not in v1.
- Output dedupe: the app only sends a bulb's color when it differs from the last sent color by a visible amount, so quiet passages send nothing.

Testing: feed scripted `AudioFrame` sequences (silence, steady tone, a metronome of bass bursts) and assert beats fire at the right ticks and each effect emits the expected colors.

### 4.4 App (SwiftUI)

State: one `AppModel` (observable) owning discovery, the controller, the poller, the tap, and the party engine. Views read from it. Bulb names and order are stored in `UserDefaults` keyed by bulb id, since Govee's cloud names are not reachable without login.

Windows and views:

- **Main window**
  - Bulb list: name (editable), reachability dot, on/off toggle, brightness slider, color well, color temperature slider. An "All bulbs" row at the top applies to every bulb.
  - Party Mode panel: big toggle, effect picker (Pulse / Spread / Wave), palette picker, sensitivity slider, live level meter so the user can see the app is hearing audio.
  - Status line: "6 bulbs, listening to system audio" or the relevant problem.
- **Menu bar** (optional, Settings toggle, default off): status item with a popover containing the All row, the Party toggle, effect and palette pickers. Same `AppModel`.
- **Settings**: menu bar on/off, launch at login, rescan interval, max updates per second (default 8, range 2 to 10, for slow Wi-Fi).
- **First run**: three-step sheet. 1) "Turn on LAN Control in Govee Home for each bulb" with screenshots and a Rescan button that shows the count as bulbs appear. 2) Name your bulbs. 3) Done. The audio permission prompt is not part of first run; it fires the first time Party Mode is switched on.
- **Empty and error states**: no bulbs found (explanation plus Rescan); bulb unreachable (greyed row, controls disabled); audio permission denied or silent (banner with a button to System Settings > Privacy & Security > Screen & System Audio Recording, and a hint to check the Mac is not muted).

Party Mode lifecycle:

1. User switches it on. App starts the tap (permission prompt if first time), starts the 1 s status poll, records each bulb's pre-party state.
2. Engine ticks 8 times per second: tap frames -> beat detector -> effect -> deduped `colorwc` sends.
3. User switches it off: engine stops, each bulb gets one final `colorwc` at the palette's dim base (not the pre-party color, which would be a jarring jump). The pre-party state is discarded.
4. Quitting the app never turns bulbs off and never restores anything. Bulbs keep their last color.

Phone takeover (external change detection):

- While Party Mode runs, the poller compares each bulb's reported state with what the engine sent.
- Treated as external: onOff changed; brightness differs from what the app last set; reported color matches none of the last 5 colors the app sent to that bulb (with a tolerance of 8 per channel). (Color rule amended 2026-09-23: a 3 s time window, the fade between sent colors, and three agreeing polls. See v1.2 addendum section S.)
- On detection: Party Mode pauses for all bulbs, the toggle shows "Paused: changed from the Govee app," with a Resume button. Resume clears the pause and restarts the engine.
- Scenes started from the phone are expected to show up as an unexpected color or brightness. This is verified on real bulbs during the build; if a phone scene is not detectable, the fallback is that Party Mode keeps sending and the phone scene and the Mac fight, which is documented as a known limitation rather than solved in v1.

## 5. Things deliberately out of v1

- Bluetooth transport.
- Cloud login, Govee scenes, DIY modes, schedules.
- Custom palettes, per-bulb effect assignment, screen color sync.
- App Store distribution and sandboxing.
- Other Govee SKUs. Discovery records the SKU and the app treats any bulb that answers `devStatus` as controllable, but only H6004 is tested.
- Any payment.

## 6. Testing and verification plan

- Unit tests in each package (XCTest), run with `xcodebuild test` and zero warnings.
- `FakeBulb` lets the app's Party Mode engine run end to end in tests with synthetic audio frames.
- Manual on-hardware checklist, run with the warn-then-run routine (tell Phil what to watch, 10 s delay, then run):
  1. Discovery finds 6 bulbs within 3 s of launch.
  2. Per-bulb and All controls change the real bulbs and the status readback matches.
  3. Party Mode with music playing: each of the three effects visibly follows the beat.
  4. Sensitivity slider visibly changes how often bulbs react.
  5. Phone takeover: change brightness in Govee Home during Party Mode, the app pauses within 2 s.
  6. Audio permission denied path shows the banner.
  7. Menu bar toggle shows and hides the status item without restart.
- Codex review of the finished code before Phil's first install.

## 7. Delivery

- Xcode project at `~/Projects/glowbeat`, macOS 14.4 minimum (process taps), Swift 6 strict concurrency.
- Build and run locally on Phil's Mac, signed with the personal team (see `~/.claude/CLAUDE.md` for the account), then a notarized `.app` in a zip for direct download when it is ready for other people.
