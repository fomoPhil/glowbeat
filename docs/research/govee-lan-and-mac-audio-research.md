# Govee H6004 → Mac system-audio "music mode" — research report

Date 2026-09-11. Revised after confirmation that the bulbs are **H6004**, firmware `wifiVersionSoft 1.01.27`, with LAN API enabled and `scan` / `devStatus` / `turn` / `brightness` / `colorwc` all working over UDP 4001/4003.

---

## TL;DR

**Do not use `razer` on these bulbs. Use `ptReal` carrying the bulb's BLE music-mode frames.**

The H6004 is a single-zone bulb. `razer` (`0xBB…0xB0`) is the DreamView/Chroma *segment stream* built for strips, bars and panels — an H6004 is very unlikely to implement it. But `ptReal` is a generic **BLE-over-LAN relay** in the same LAN firmware you already have working, and the H6004's BLE command set has a documented, byte-verified **instant music-mode colour** sub-command that the official Govee app streams at ~20 Hz.

**The two packets that matter:**

| Purpose | 20-byte frame (hex) | base64 for `ptReal` |
|---|---|---|
| Enter music mode (send once) | `3305050100000000000000000000000000000032` | `MwUFAQAAAAAAAAAAAAAAAAAAADI=` |
| Set colour **instantly** (stream this) | `33 05 05 00 RR GG BB` + zero-pad to 19 + XOR | e.g. red `MwUFAP8AAAAAAAAAAAAAAAAAAMw=` |

Wrapped for the wire, to `<bulb-ip>:4003`:

```json
{"msg":{"cmd":"ptReal","data":{"command":["MwUFAQAAAAAAAAAAAAAAAAAAADI="]}}}
{"msg":{"cmd":"ptReal","data":{"command":["MwUFAP8AAAAAAAAAAAAAAAAAAMw="]}}}
```

Confidence that these are the correct *BLE* frames for an H6004: **high** (byte-for-byte HCI snoop captures, reproduced and confirmed on real H6004 hardware by an independent researcher).
Confidence that `ptReal` relays them over LAN on your firmware: **moderate — untested, and it is the one thing you must verify empirically.** A 5-minute test script is in section 4.

**Why not `colorwc` for music mode:** the same reason `0x0D` fails over BLE. It's a *fade*, ~0.3-1 s ramp. At 12 Hz every frame interrupts the previous ramp and red/green alternation renders as muted orange. Confidence: high.

---

## 1. Does H6004 accept `razer` / `ptReal` style realtime LAN commands?

### `razer` — almost certainly not, and you don't want it anyway

`razer` is the Razer Chroma / DreamView ingestion path. Format (verified, OpenRGB):

```
{"msg":{"cmd":"razer","data":{"pt":"<base64>"}}}

binary: 0xBB, len_hi, len_lo, <subcmd>, <data...>, <XOR of all preceding bytes>

subcmd 0xB1  enable/disable protocol   1 byte bool
subcmd 0xB0  LED data
             byte 0: gradient flag (0 = per-segment, 1 = stretch)
             byte 1: colour count N
             byte 2+: N × (R,G,B)
             length field = 2 + 3*N
```

Ready-made packets, should you want to probe anyway:

| Packet | hex | base64 |
|---|---|---|
| Enable razer mode | `bb0001b1010a` | `uwABsQEK` |
| Disable razer mode | `bb0001b1000b` | `uwABsQAL` |
| One colour, red | `bb0005b00001ff0000f0` | `uwAFsAAB/wAA8A==` |

Firmware auto-disables razer mode after **60 s with no LED data packet** (OpenRGB MR !2172), so a probe must keep streaming.

**Why I expect it to fail on H6004:**
- Every project's confirmed-working razer list is strips/bars/panels: LedFx names H6061, H6167, H61BA, H61D5, H615C. LedFx docs explicitly: *"Bulbs aren't mentioned as supported devices."*
- The **Govee Windows Desktop app you have on disk** hardcodes its realtime-capable SKU list in `GoveeAPI/GoveeAPI.dll` (FileDescription "ThirdInterface"): `H610A, H6056, H6047, H610B, H6046, H6608, H6609, H606A, H6065, H6066, H6067, H6061`. **No bulbs of any kind.** That is Govee's own list of what its realtime pipeline targets.
- The `razer` `0xB0` payload carries a *segment array*; `iAmChumby/govee-cli`'s H6004 handler states the model "advertises no segments, segment brightness, music mode or toggles" over the cloud API.

Confidence razer works on H6004: **low**. Cost to test anyway: ~2 minutes. Worth doing, because a yes would be strictly better (fewer bytes, purpose-built).

### `ptReal` — the right answer, and plausible on your firmware

`ptReal` is **not** a segment stream. It is a relay: it takes 20-byte Govee **Bluetooth** frames, base64-encoded, and injects them into the device's own command handler over LAN.

Wire format (verified from `wez/govee2mqtt` `src/lan_api.rs`, MIT — `#[serde(rename = "ptReal")] PtReal { command: Vec<String> }`, sent to `CMD_PORT = 4003`):

```json
{"msg":{"cmd":"ptReal","data":{"command":["<base64 frame>", "<base64 frame>", ...]}}}
```

Note `command` is an **array** — you can batch several frames in one datagram.

This is how the community activates scenes and DIY modes on LAN devices that the documented `turn`/`brightness`/`colorwc` vocabulary can't reach. Since your bulbs run the LAN firmware stack (they answer `scan`/`devStatus`), `ptReal` is part of the same handler family. Confidence it is present: **moderate**. Confidence the *inner* `0x33 05 05` frames are right for H6004: **high**.

---

## 2. The exact packets a single-zone H6004 needs

### Source of truth

`egold555/Govee-Reverse-Engineering` has a dedicated, unusually rigorous H6004 page:
https://github.com/egold555/Govee-Reverse-Engineering/blob/master/Products/H6004.md
plus the originating write-up: https://github.com/Beshelmek/govee_ble_lights/issues/92

Methodology stated there: *"captured from the official Android app with the phone's Bluetooth HCI snoop log, rebuilt byte-for-byte, and then confirmed against the bulbs."* Verified on both H6004 and H6005. Confidence: **high**.

### Frame envelope

```
20 bytes total:
  byte 0     : 0x33   (command frames)  |  0xAA  (keepalive only)
  byte 1     : command
  bytes 2..18: payload, zero-padded
  byte 19    : XOR of bytes 0..18
```

I re-derived the checksum independently and reproduced the document's published hex exactly, so the algorithm is confirmed:

```python
def frame(body: bytes) -> bytes:
    b = bytearray(body) + bytearray(19 - len(body))
    x = 0
    for c in b: x ^= c
    b.append(x)
    return bytes(b)
```

### Command map for H6004

```
0x01  power        [0x00 | 0x01]
0x04  brightness   [0-100]      <- NOT 0-255 on this model
0x05  colour       [sub-command, ...]
      sub 0x0D  fade to colour  (and colour temperature)
      sub 0x05  music mode      (instant, no fade)
0xAA  keepalive (BLE only, irrelevant over LAN)
```

### The music-mode pair (this is the whole trick)

```
0x33 05 05 01           enter music mode      send ONCE
0x33 05 05 00 R G B     set colour NOW        stream this
```

> `0x0D` ramps to its colour over roughly 0.3 to 1 s. That is fine for a scene and useless for streaming: at 12 Hz each frame interrupts the previous ramp and the bulb never arrives, so a red/green alternation renders as a muted orange. The app's music mode uses a separate sub-command that applies immediately.

**Warning, straight from the source, and it bit the researcher:**

> **Send the enter frame once per session.** The app does. Re-sending it about once a second, as a defence against a lost write, left bulbs in a state where they still obeyed `0x05` colour frames but ignored power, brightness, and `0x0D` entirely, and **a mains power cycle did not clear it.**

(The same author's earlier issue text recommended re-sending it ~1/s; the later, corrected Products page says don't. Take the Products page. If you get a wedged bulb, you will likely need to reset it in the Govee app.)

### Precomputed packets

| Meaning | hex | base64 |
|---|---|---|
| enter music mode | `3305050100000000000000000000000000000032` | `MwUFAQAAAAAAAAAAAAAAAAAAADI=` |
| music colour red | `33050500ff0000000000000000000000000000cc` | `MwUFAP8AAAAAAAAAAAAAAAAAAMw=` |
| music colour green | `3305050000ff00000000000000000000000000cc` | `MwUFAAD/AAAAAAAAAAAAAAAAAMw=` |
| music colour blue | `330505000000ff000000000000000000000000cc` | `MwUFAAAA/wAAAAAAAAAAAAAAAMw=` |
| music colour white | `33050500ffffff000000000000000000000000cc` | `MwUFAP///wAAAAAAAAAAAAAAAMw=` |
| music colour black/off | `3305050000000000000000000000000000000033` | `MwUFAAAAAAAAAAAAAAAAAAAAADM=` |
| fade red (`0x0D`, scene use) | `33050dff000000000000000000000000000000c4` | `MwUN/wAAAAAAAAAAAAAAAAAAAMQ=` |
| power on | `3301010000000000000000000000000000000033` | `MwEBAAAAAAAAAAAAAAAAAAAAADM=` |
| power off | `3301000000000000000000000000000000000032` | `MwEAAAAAAAAAAAAAAAAAAAAAADI=` |
| brightness 100% | `3304640000000000000000000000000000000053` | `MwRkAAAAAAAAAAAAAAAAAAAAAFM=` |

The first two match the published hex in the H6004 doc character for character.

### Colour temperature, for completeness

```
0x33 05 0D  R G B  K_hi K_lo  R G B      <- RGB repeated after the Kelvin
```
Kelvin is 16-bit big-endian. **H6004 floors at 2700 K** (H6005 reaches 2000 K).
```
33050dffa9570a8cffa9570000000000000000bd   2700 K
33050deeefff1d4ceeefff00000000000000006a   7500 K
```

### Traps that will waste your afternoon

1. **Sub-command `0x02` (the "manual" mode of the H6001 generation) is acked and silently ignored** on this bulb. Use `0x0D` / `0x05`.
2. **Acks prove receipt, never compliance.** The bulb echoes the command byte with a zeroed payload whether it acted or not. Over LAN it's worse: UDP is fire-and-forget with no ack at all. **Verify by looking at the light.**
3. **Brightness is 0-100 on H6004, 0-255 on H6005.** `0xFF` clamps to full, so a scale bug hides.
4. The bulb **restores its last state on mains power-on**. Leave it red and the wall switch brings back red.
5. The cloud API reflects a *brightness* set locally but **not** a *colour* set locally — so cloud readback is a valid instrument for brightness and an invalid one for colour.

### One flag on the source

The H6004 page's transport table says Govee LAN API = **"no — the bulb does not answer the UDP multicast scan"**. **Your firmware (`1.01.27`) contradicts that, and your empirical result wins.** Most likely a firmware-version or hardware-revision difference. Treat that row as stale, and treat it as a reminder that H6004 LAN behaviour is *not* uniform across the fleet — test each bulb.

---

## 3. Update rate: what bulbs tolerate

| Data point | Value | Source | Confidence |
|---|---|---|---|
| Govee's own Android app, music mode over BLE, H6004 | **~20 Hz (50 ms)** | HCI snoop of the official app | high |
| Researcher's reproduced streaming test, H6004/H6005 | 12 Hz gives "sharp saturated colours" with `0x05` | same | high |
| LedFx default for Govee over LAN `razer` | **40 Hz** (*"from very limited testing"*) | https://docs.ledfx.app/en/latest/devices/govee.html | high |
| Firmware throttle on `ptReal` | **unknown** — nobody documents one | — | unknown |
| razer mode auto-off | 60 s without an LED packet | OpenRGB MR !2172 | high |
| H6008-generation cloud latency (sanity floor) | ~1.5 s | wez/govee2mqtt#144 | moderate |

**Practical plan: target 20 Hz, ceiling 30 Hz, floor 10 Hz.**

Reasoning:
- 20 Hz is what the vendor's own app does on this exact model, so the firmware is known to keep up.
- LAN adds Wi-Fi jitter but removes BLE's connection-interval constraint, so 20 Hz over LAN should be no worse than 20 Hz over BLE.
- **Six bulbs × 20 Hz = 120 datagrams/sec** of ~100 bytes on 2.4 GHz Wi-Fi. That's trivial bandwidth but non-trivial *airtime* for cheap IoT radios. Watch for the bulbs dropping off the network, and back off to 10-12 Hz if they do.
- Make the rate a user-visible slider. You cannot predict this and neither can anyone else.

**Two engineering notes that matter more than raw Hz:**
- **Software decay envelope.** The Govee app computes its own decay in software — `fe → aa → 56 → 14`, one frame per step — precisely because `0x05` steps instantly with no firmware smoothing. You must do the same, or the lights will look like a strobe. Attack fast, release over ~4-8 frames.
- **Deduplicate.** Don't send a frame when the colour hasn't changed meaningfully. Cuts traffic hugely on quiet passages.
- **Batch.** `ptReal`'s `command` field is an array, so you *may* be able to send all six bulbs' frames… no — `ptReal` is unicast to one device IP, so the array batches multiple frames *for one bulb*. Six bulbs = six datagrams per frame. Fire them in one tight loop; UDP sends don't block.

---

## 4. The 10-minute test you should run before writing any Swift

This settles every remaining unknown. Save and run it with your bulb's IP.

```python
#!/usr/bin/env python3
# govee_probe.py <bulb-ip>
import base64, json, socket, sys, time

IP = sys.argv[1]; PORT = 4003
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 4002))          # some firmwares only reply to source port 4002

def ble(body):                      # 20-byte Govee BLE frame
    b = bytearray(body) + bytearray(19 - len(body)); x = 0
    for c in b: x ^= c
    b.append(x); return bytes(b)

def send(obj):
    s.sendto(json.dumps(obj).encode(), (IP, PORT)); time.sleep(0.02)

def ptreal(*frames):
    send({"msg": {"cmd": "ptReal",
                  "data": {"command": [base64.b64encode(f).decode() for f in frames]}}})

def razer(pt):
    send({"msg": {"cmd": "razer", "data": {"pt": base64.b64encode(pt).decode()}}})

def rz(body):
    x = 0
    for c in body: x ^= c
    return bytes(body) + bytes([x])

print("baseline: on, 100%")
send({"msg":{"cmd":"turn","data":{"value":1}}})
send({"msg":{"cmd":"brightness","data":{"value":100}}})
time.sleep(1)

# --- TEST A: does ptReal relay BLE frames at all? ---
print("A: ptReal + 0x0D fade -> should go RED (slow fade)")
ptreal(ble([0x33,0x05,0x0D,0xff,0x00,0x00])); time.sleep(2)

# --- TEST B: music mode, the one that matters ---
print("B: enter music mode, then 12 Hz red/green for 6 s")
ptreal(ble([0x33,0x05,0x05,0x01])); time.sleep(0.3)
t0 = time.time()
while time.time() - t0 < 6:
    for rgb in ((255,0,0), (0,255,0)):
        ptreal(ble([0x33,0x05,0x05,0x00,*rgb])); time.sleep(1/12)
print("   -> SHARP red/green = ptReal music mode WORKS. Muddy orange = fades, not instant.")
time.sleep(1)

# --- TEST C: rate ceiling ---
for hz in (10, 20, 30, 40):
    print(f"C: {hz} Hz sweep, 4 s")
    t0 = time.time()
    while time.time() - t0 < 4:
        p = (time.time() - t0) / 4
        rgb = (int(255*abs(1-2*p)), int(255*p), int(255*(1-p)))
        ptreal(ble([0x33,0x05,0x05,0x00,*rgb])); time.sleep(1/hz)
    time.sleep(0.5)
print("   -> note the highest Hz that still looks smooth and doesn't drop the bulb off Wi-Fi")

# --- TEST D: long shot, razer ---
print("D: razer enable + red (expect nothing)")
razer(rz([0xBB,0x00,0x01,0xB1,0x01])); time.sleep(0.3)
t0 = time.time()
while time.time() - t0 < 4:
    razer(rz([0xBB,0x00,0x05,0xB0,0x00,0x01,255,0,0])); time.sleep(0.05)
razer(rz([0xBB,0x00,0x01,0xB1,0x00]))

# --- cleanup ---
send({"msg":{"cmd":"colorwc","data":{"color":{"r":255,"g":255,"b":255},"colorTemInKelvin":4000}}})
print("done")
```

**Decision tree from the result:**

| Result | Build |
|---|---|
| B is sharp | `ptReal` + `0x33 05 05` at 20 Hz. Ship it. |
| A works, B is muddy | `ptReal` + `0x0D` at ~2-3 Hz. "Mood shifts with the track", not a visualizer. |
| A and B both do nothing, D works | Unexpected but great: use `razer` with N=1. |
| Nothing but `colorwc` works | `colorwc` at ~2-3 Hz, accept the fade, or switch to BLE (section 6). |

---

## 5. macOS system-audio capture for a native Swift app

### Recommendation: CoreAudio process taps

`CATapDescription` + `AudioHardwareCreateProcessTap` + a private aggregate device. It is the only approach that is audio-only by design, needs no user setup, no virtual driver, no Screen Recording permission, and no menu-bar recording indicator. Confidence: **high**.

| | (a) CoreAudio process tap | (b) ScreenCaptureKit audio | (c) BlackHole / virtual device |
|---|---|---|---|
| Min macOS | API 14.2, practically **14.4+** | 13.0 | any |
| Permission | TCC `kTCCServiceAudioCapture` + `NSAudioCaptureUsageDescription` in Info.plist. **No entitlement.** | **Screen & System Audio Recording** TCC, even audio-only | none |
| User setup | one prompt, first run | one prompt + **Sequoia/Tahoe re-prompt periodically** | high: install driver, build a Multi-Output Device in Audio MIDI Setup, switch output |
| Audio-only viable | yes, natively | **no** — SCK refuses an audio-only stream; you must attach a dummy video output and throw frames away | yes |
| Breaks the Mac's audio | no | no | **yes-ish** — Multi-Output Device greys out the volume keys |
| Code complexity | medium-high (raw CoreAudio C API) | medium, but wasteful | low in-app, high for the user |

You are on macOS 26 (Darwin 25.6), so the 14.4 floor is irrelevant.

### (a) CoreAudio process taps — the detail

Public API, not private. Apple docs + sample: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

Shape, verified from `insidegui/AudioCap`'s `ProcessTap.swift`:

```swift
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [myAudioObjectID])
desc.uuid = UUID()
desc.muteBehavior = .unmuted
var tapID: AUAudioObjectID = .unknown
AudioHardwareCreateProcessTap(desc, &tapID)

let outputUID = try AudioDeviceID.readDefaultSystemOutputDevice().readDeviceUID()
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Tap-…",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: desc.uuid.uuidString
    ]]
]
AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue, ioBlock)
AudioDeviceStart(aggregateDeviceID, procID)
```

Teardown: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`. **The aggregate device is mandatory** — a tap alone produces nothing.

Permissions:
- `NSAudioCaptureUsageDescription` in Info.plist: **required**. Confidence high.
- `com.apple.security.device.audio-input`: not needed unsandboxed; sandboxed case **unknown**.
- Screen Recording: **not** required. Confidence high.
- There **is** a first-run prompt. Apple DTS: *"The system prompts the user to grant your app system audio recording permission the first time it starts recording from an aggregate device that contains a Core Audio tap"* — https://developer.apple.com/forums/thread/771864

Gotchas, all load-bearing:

1. **Everything returns `noErr` even when permission is denied** — you just get buffers of zeros. Only reliable signal is "all samples silent". https://www.thunderkitty.app/learn/2000-buffers-of-nothing/
2. The TCC prompt fires on **`AudioDeviceStart`**, not at tap creation. To prompt during onboarding, build → start → stop.
3. **No public API to query permission state.** AudioCap uses TCC SPI behind an `ENABLE_TCC_SPI` flag — fine for Developer ID, risky for the App Store.
4. The `INFOPLIST_KEY_NSAudioCaptureUsageDescription` build setting is **silently ignored**. Use a real Info.plist; verify with `plutil -p`.
5. **`AVAudioEngine` cannot be retargeted to a tap-backed aggregate device** — setting `kAudioOutputUnitProperty_CurrentDevice` returns `noErr` then quietly reads the default *input*. Use `AudioDeviceCreateIOProcIDWithBlock` directly. https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html
6. Prefer **built-in output** as `kAudioAggregateDeviceMainSubDeviceKey` over *default* output — default changes when AirPods connect.
7. Must be **code-signed**. Unsigned builds never get the TCC grant.
8. Read the real format via `kAudioTapPropertyFormat`. Don't assume 48k stereo float.

**macOS 26 notes:** the Settings pane is now "Screen & System Audio Recording". A 26.1 regression hides plain non-bundled executables from that list (the grant still works, it's just invisible), reportedly fixed in 26.3 beta — confirmed for ScreenCaptureKit; **unknown** whether it affects taps. Ship a proper `.app` bundle and it's moot. https://developer.apple.com/forums/thread/807898

Swift references:
- https://github.com/insidegui/AudioCap — canonical; start from `ProcessTap.swift`
- https://github.com/makeusabrew/audiotee — SwiftPM library + CLI, global tap excluding self
- https://swiftpackageindex.com/CJStanfield/CoreAudioTapKit
- https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f

### (b) ScreenCaptureKit — why it loses

- **No audio-only mode.** `SCStream` errors without a video output attached; the standard hack is a 2×2 dummy video size with `minimumFrameInterval = CMTime(value: 1, timescale: 1)`, discarding every frame. https://developer.apple.com/forums/thread/718279
- Requires Screen Recording TCC even audio-only. Confidence high.
- Sequoia 15 added **weekly re-prompting** for screen capture, kept in Tahoe 26, no opt-out. No Apple statement exempts audio-only SCK, so assume it applies. Confidence moderate. For a menu-bar toy that is a recurring scary dialog.
- Adds a menu-bar recording indicator.
- Working knobs: `capturesAudio = true`, `sampleRate`, `channelCount`, `excludesCurrentProcessAudio`.

### (c) BlackHole — fallback only

https://github.com/ExistentialAudio/BlackHole — free, driverless install. User must install it, open Audio MIDI Setup, create a Multi-Output Device with Built-in Output **first**, and switch system output to it.

**Killer caveat: macOS cannot control the volume of a Multi-Output Device.** Volume keys grey out. https://github.com/ExistentialAudio/BlackHole/wiki/Multi-Output-Device

Only advantage: zero permission prompts.

### Is there a cheap "just give me the output level" API?

**No.** Confidence high. `kAudioDevicePropertyVolumeDecibels` is the **slider position**, not signal level. There is no public HAL property that meters another app's output. `kAudioQueueProperty_EnableLevelMetering`, `AVAudioPlayerNode` metering and `kAudioUnitProperty_MeteringMode` only meter audio passing through *your own* object. You have to capture.

### Concrete build shape

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [myAudioObjectID])`, `muteBehavior = .unmuted`.
2. Private aggregate device (`kAudioAggregateDeviceIsPrivateKey: true`, `kAudioAggregateDeviceTapAutoStartKey: true`) on the built-in output UID.
3. `AudioDeviceCreateIOProcIDWithBlock` on a `.userInitiated` queue. Compute RMS and a small **vDSP** FFT there (`vDSP_DFT_zop_CreateSetup`, 1024-point is plenty). Split into 3 bands (bass / mid / treble) and map to hue/brightness.
4. A 20 Hz `DispatchSourceTimer` reads the latest smoothed band values and fires one `ptReal` datagram per bulb. Apply the software decay envelope (fast attack, ~4-8 frame release) — the bulb does no smoothing of its own.
5. `NSAudioCaptureUsageDescription` in a real Info.plist, verified with `plutil -p`, signed with Developer ID.
6. Onboarding: build → start → stop once to trigger the prompt; detect denial via N consecutive all-zero buffers and nudge the user to System Settings → Privacy & Security → Screen & System Audio Recording.

---

## 6. Fallbacks, ranked

| Option | Realtime? | Notes |
|---|---|---|
| **`ptReal` + `0x33 05 05` over LAN** | **yes, ~20 Hz** | The plan. Test first. |
| `razer` over LAN | yes, ~40 Hz | Unlikely on a bulb. Probe anyway, it's free. |
| **Direct BLE via CoreBluetooth** | yes, ~20 Hz | **Fully documented and hardware-verified for H6004** (section 2). Service `00010203-0405-0607-0809-0a0b0c0d1910`, control char `…0d2b11`, notify `…0d2b10`. **Must use write-WITHOUT-response** — the H6004 enforces it and returns "Write not permitted" otherwise. In Swift: `peripheral.writeValue(frame, for: char, type: .withoutResponse)`. Keepalive `aa010000…ab` every ~2 s or the link drops after ~15 s idle; **only a write resets the timer, a read does not**. Risk: 6 concurrent BLE links on one Mac radio is untested — **unknown**. |
| `colorwc` over LAN at 2-3 Hz | no | Fades. "Mood shifts with the track." Always works. |
| Govee Cloud OpenAPI v2 | no | **10 requests/min/device**, 10,000/day. One change per 6 s per bulb. Dead for music mode; fine for the on/off/scene half of the app. https://govee.readme.io/reference/rate-limiting |

**BLE is a genuinely strong plan B** and the only path with byte-level verification *on this exact model*. If `ptReal` fails the test, go straight there rather than settling for `colorwc`.

---

## 7. Bonus: your local Govee Desktop 2.40.60 copy

`/Users/philwoolley/Desktop/GoveeDesktop2.40.60` is .NET **with `.pdb` files shipped alongside**, so it decompiles cleanly with ILSpy / `ilspycmd`. Findings from a strings pass alone:

- `Govee.Infrastructure.Shared.dll` contains the literal `239.255.255.250`, plus `https://gapp.govee.com`, `https://desktop.govee.com`, `/bff-app/v1/pc/login`.
- `GoveeAPI/GoveeAPI.dll` (FileDescription **"ThirdInterface"**, © 2023) is a named-pipe SDK (`GoveePipe` / `GoveeDesktopPipe`) exposing the LAN vocabulary to third parties. Its UTF-16 literals: `turn`, `brightness`, `colorwc`, `razer`, `4000`, `4001`, and templates `{{ msg = {0} }}`, `{{ cmd = {0}, data = {1} }}`, `{{ color = {0}, colorTemInKelvin = {1} }}`, `{{ r = {0}, g = {1}, b = {2} }}`, `{{ pt = {0} }}`, `{{ value = {0} }}`, `{{ Name = {0}, SegmentNums = {1}, SkuType = {2}, IsLANOn = {3} }}`.
- Its hardcoded realtime SKU list: `H610A, H6056, H6047, H610B, H6046, H6608, H6609, H606A, H6065, H6066, H6067, H6061` — **no bulbs** (the razer evidence above).
- `Govee.Application.dll` has `RazerService`, `DreamviewService`, `MusicDreamviewService` with `ShowEnergyEffect`, `ShowRhythmEffect`, `ShowSlideEffect`, `ShowSwingEffect`, `ShowAlternateEffect` — **Govee's own music-mode effect algorithms, decompilable.** Worth an hour if you want their exact band mapping and decay curves.
- Discovery is layered: `GetLanDevicesByUdpAsync`, `GetLanDevicesByIcmpAsync`, `GetLanDevicesByIotAsync` — it falls back to ICMP sweep and cloud-reported IPs when multicast fails. Worth copying; multicast on consumer Wi-Fi is unreliable.
- Bundled **`NAudio.Wasapi.dll` + `MathNet.Numerics` + `MathNet.Filtering`** confirms the Windows app does exactly what you want: WASAPI **loopback** capture of system output → FFT/filtering → light effects. CoreAudio process taps are the direct macOS analogue.
- Also: `SharpDX.DXGI` (desktop duplication for screen sync), `OpenCvSharp`, `M2Mqtt` (cloud IoT), `TouchSocket` (UDP/TCP layer).

---

## 8. Confidence summary

| Claim | Confidence |
|---|---|
| H6004 BLE frame envelope: 20 bytes, `0x33`, XOR of first 19 | high (independently re-derived, matches published hex) |
| `0x33 05 05 01` enters music mode; `0x33 05 05 00 RGB` sets colour instantly | high (HCI capture, confirmed on H6004 hardware) |
| `0x0D` fades and is unusable for streaming | high |
| Sub-command `0x02` is acked and ignored on H6004 | high |
| H6004 brightness is 0-100, not 0-255 | high |
| Do NOT re-send the music-mode enter frame repeatedly | moderate-high (source corrected itself; failure mode was persistent) |
| `ptReal` wire format `{"msg":{"cmd":"ptReal","data":{"command":[...]}}}` to port 4003 | high (govee2mqtt source) |
| `ptReal` is available on H6004 firmware 1.01.27 | **moderate — untested** |
| `razer` works on H6004 | low |
| ~20 Hz is a safe streaming target | moderate-high |
| Any firmware rate limit on `ptReal` | unknown |
| 6 bulbs × 20 Hz on one 2.4 GHz network is fine | unknown |
| CoreAudio process taps are the right macOS capture path | high |
| ScreenCaptureKit audio-only still triggers Tahoe re-prompts | moderate |
| Direct BLE from CoreBluetooth works on H6004 | high for the protocol, unknown for 6 concurrent links |
| Cloud API: 10/min/device, 10,000/day | high |

---

## 9. Sources

H6004 protocol (primary)
- https://github.com/egold555/Govee-Reverse-Engineering/blob/master/Products/H6004.md
- https://github.com/Beshelmek/govee_ble_lights/issues/92
- https://github.com/egold555/Govee-Reverse-Engineering
- https://github.com/iAmChumby/govee-cli (`govee_cli/devices/h6004.py`)
- https://github.com/chvolkmann/govee_btled/issues/13

LAN protocol
- https://github.com/wez/govee2mqtt/blob/main/src/lan_api.rs (`PtReal { command: Vec<String> }`, `CMD_PORT = 4003`)
- https://github.com/wez/govee2mqtt/blob/main/docs/LAN.md
- https://deepwiki.com/wez/govee2mqtt/3.1-lan-api
- https://gitlab.com/CalcProgrammer1/OpenRGB/-/merge_requests/2172 (razer format + 60 s timeout)
- https://github.com/CalcProgrammer1/OpenRGB (`Controllers/GoveeController/`)
- https://github.com/LedFx/LedFx/blob/main/ledfx/devices/govee.py
- https://docs.ledfx.app/en/latest/devices/govee.html (40 Hz default)
- https://www.openhab.org/addons/bindings/govee/ (4001/4002/4003 firewall spec)
- https://github.com/Minlor/LumiSync/blob/main/docs/govee-lan-research-and-implementation.md (Govee Desktop 2.40.20 traffic teardown)
- https://app-h5.govee.com/user-manual/wlan-guide (JS-rendered, not machine-readable)

Cloud API
- https://govee.readme.io/reference/rate-limiting
- https://developer.govee.com/docs/support-product-model

macOS audio capture
- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- https://github.com/insidegui/AudioCap
- https://github.com/makeusabrew/audiotee
- https://developer.apple.com/forums/thread/771864
- https://developer.apple.com/forums/thread/718279
- https://developer.apple.com/forums/thread/807898
- https://www.thunderkitty.app/learn/2000-buffers-of-nothing/
- https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html
- https://github.com/ExistentialAudio/BlackHole/wiki/Multi-Output-Device

Swift / Mac Govee prior art
- https://github.com/SeanPVera/LumenDesk (Swift, MIT, macOS 13+, razer + ptReal + ScreenCaptureKit music mode; 0 stars, unverified)
- https://github.com/hyperb1iss/hypercolor (Rust, Apache-2.0, very new)
