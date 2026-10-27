# FreeBee

The companion app from [`docs/IOS_PLAN.md`](../../docs/IOS_PLAN.md): status and controls for the Bee
over Bluetooth, built from [`docs/PROTOCOL.md`](../../docs/PROTOCOL.md), plus the local audio pipeline
from [`reports/Local Bee audio pipeline on iPhone.md`](reports/Local%20Bee%20audio%20pipeline%20on%20iPhone.md):
capture all day, transcribe, separate speakers and take notes on the iPhone. No account or server.

## Layout

| Path | What's in it |
|---|---|
| `BeeKit/` | Swift package. `BeeProtocol` is a pure port of `mac/src/beekit/protocol.py` (framing, command ids, decoders, advertisement, token, CBOR, SMP) plus the audio stream (AES-128-CTR, ADTS reassembly). `BeeKit` adds the CoreBluetooth central, the peripheral transport, the serialized request client, the read-only SMP client, the audio recorder and a simulated Bee. `BeePipeline` is everything after capture: decoding, VAD, transcription, speakers and notes. |
| `FreeBee/` | The app target (SwiftUI). `Model/BeeStore.swift` runs the connection; `Views/` holds the screens. |
| `BeeWidget/` | Home Screen and Lock Screen widget (battery and state). |
| `Shared/` | The snapshot the app writes to the App Group and the widget reads. |
| `Support/` | Info.plists and entitlements. |
| `BeeUITests/` | UI tests that drive the simulated Bee. |

## Build and test

Open `FreeBee.xcodeproj` in Xcode 27 and run the `FreeBee` scheme on an iPhone (iOS 27).
Bluetooth doesn't work in the simulator; use **Try the Demo** there, or launch with `-demo YES`.

To run on a device, sign it as your own: in the project's build settings set `BEE_APP_BUNDLE_ID` (default
`com.example.FreeBee`) to an identifier you own, and pick your team under Signing & Capabilities for the
`FreeBee`, `BeeWidgetExtension` and `BeeUITests` targets. The widget's bundle id and the App Group
(`group.<bundle id>`) follow from `BEE_APP_BUNDLE_ID`.

```bash
cd BeeKit && swift test        # protocol, audio, capture and pipeline tests, no device needed
BEE_MODEL_TESTS=1 swift test --filter runsTheModels   # runs VAD, Parakeet, diarization and notes on a capture
xcodebuild test -project "FreeBee.xcodeproj" -scheme FreeBee \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -parallel-testing-enabled NO
```

## Pairing

Pairing goes through **AccessorySetupKit** by default: the system sheet finds a Bee in pairing mode
(5 presses, light flashes blue-green), and CoreBluetooth then sees only that Bee, with no Bluetooth
permission prompt. Since iOS 26 only AccessorySetupKit apps are relaunched by Bluetooth state
restoration, which the background reconnect relies on.

AccessorySetupKit and plain CoreBluetooth scanning can't be mixed in one build, so the fallback is a
build setting: set `BEE_PAIRING = CoreBluetooth` (project build settings) to use
`Support/Bee-CoreBluetooth.plist`, which asks for Bluetooth permission and shows a scan list instead.

The Bee is only connected to one device at a time. Pairing the Mac afterwards means pairing the iPhone
again (Settings › Forget This Bee, then set it up).

## Audio key

Mute and unmute only stick inside a session opened with the pairing token. On the Mac, AirDrop
`~/.config/beekit/secrets.json` to the iPhone and open it with FreeBee (or import it from Files, or paste
the `token_hex`). The token goes in the Keychain (this device only, readable after first unlock so a
background reconnect can use it) and the AirDropped copy is deleted. The app shows the same `key#`
fingerprint that `beekit` prints.

## Audio pipeline

Capture all day, think later. The Bee keeps no audio, so the iPhone has to stay connected and store what
arrives; the heavy work runs in the foreground, on "Process Now", or overnight on the charger.

1. **Capture** (`BeeKit/AudioCapture`, `AudioRecorder`), on the Bluetooth wake path only: with the key on
   file the app opens the session on every connection (SetEncryptionKey, GetSessionNonce), subscribes to
   the audio characteristic, decrypts each notification (CommonCrypto AES-CTR, IV = nonce ‖ seq), reassembles
   ADTS frames and appends them unchanged to 15-minute segment files (about 14 MB an hour) in
   `Application Support/Recordings`, out of backups. A connection only counts as capturing once frames that
   decrypt and chain arrive. The Bee's own state decides whether it records: a press of its button or
   Unmute in the app; the app never turns the microphone on by itself, not even after a reconnect. A
   watchdog re-subscribes if audio stops while the Bee says it's recording. Link stats (packets,
   loss, MTU) go to the event log.
2. **Speech** (`SpeechScanner`): Silero VAD on the CPU finds speech in each closed segment. Segments with no
   speech are deleted (a setting).
3. **Conversations** (`ConversationPlanner`): speech with no silence longer than the gap (2 min by default).
   Anything with at least 2 s of speech is kept: the Bee only records when asked, so a short note to self
   counts. Each run logs what it did ("1 new conversation, 1 transcribed", "1 recording had no speech").
4. **Words and speakers**: Parakeet TDT v3 (FluidAudio, Core ML; about 480 MB, downloaded once) or Apple's
   SpeechTranscriber; pyannote community-1 diarization; voices matched against saved voiceprints. Until you
   tell it which voice is yours, the loudest one is taken to be "Me".
5. **Notes** (`NoteTaker`): Apple's on-device model, map-reduce over 4K-token chunks with `@Generable`
   output: title, summary, to-dos with the quote they came from, and a media flag (no to-dos from the TV).
   Each day gets a commitments-first digest. Never Private Cloud Compute.

When it runs: in the foreground (Neural Engine), as a `BGContinuedProcessingTask` from "Process Now" (each
request registers its own identifier under the Info.plist wildcard; progress keeps moving inside long steps so
iOS doesn't expire it as stalled, and if it does while the app is open the run carries on in the app), or as
a `BGProcessingTask` that requires external power (no CPU monitor), scheduled when the app backgrounds with
work waiting and when the Bee goes on its charger. In the background the models run CPU only: iOS 27 keeps
the Neural Engine from background apps without the Background Inference entitlement. A run started in the
foreground stops when the app leaves the screen rather than risk the CPU monitor killing the capture too.

On-device test: a Debug build launched with `-captureSeconds 45 -processAfter YES` listens for 45 s once
the session is up, mutes again and processes what it got:

```bash
xcrun devicectl device process launch --device <udid> --terminate-existing <your.bundle.id> -- -captureSeconds 45 -processAfter YES
```

`-processNow YES` processes at launch as if "Process Now" had been tapped; `-replanFrom <ISO 8601 date>` first
plans conversations again from that time (for speech an older build dropped; it duplicates any conversation
already made from that stretch).

## What's where

Four tabs: **Bee**, **Conversations**, **To-dos** (badged with what's open) and **Settings**.

- **Bee:** one status that answers "is what I'm saying being saved?": Recording (with how long), Muted,
  Asleep, Off, Not connected, Needs the audio key, or "Not saving" when the Bee is listening but no audio has
  arrived for 15 s. It combines the Bee's state, the link and how fresh the audio is (`CaptureStatus`), and
  carries the one button that changes it (Mute, Unmute, or Import Audio Key). Green means recording, as on
  the Bee's own light; honey is for things you tap. Below it: the battery and today's recorded time.
- **Your Bee** (tap the row on the Bee tab): battery, state, signal, brightness, two sleep modes, power off
  with a confirmation; today's audio and speech, this connection's packets, loss and MTU; firmware, audio
  key, device id, hardware and codec.
- **Conversations:** by day, with each day's digest; search across what was said; tap a transcript line to hear it.
  Name speakers or mark your own voice. What people said (titles, summaries, transcripts, quotes) is set in
  New York; the app's own words in SF Pro.
  Deleting a conversation (swipe, or the detail screen) deletes its audio too: a recording with nothing else in it
  goes, and one shared with other speech has the conversation's stretch cut out (`AudioCut`). The day's digest is
  written again from what's left. "Delete Notes Only" on the detail screen keeps the audio.
- **To-dos:** the inbox: tasks for you, capped per day, each with its quote and a link to its conversation.
- **Recording light:** a Live Activity (Lock Screen and Dynamic Island) for as long as the Bee is set to
  listen, with Mute on it. Bluetooth audio doesn't turn on iOS's microphone indicator, so this is the visible
  sign (App Review 2.5.14). iOS only starts one from the foreground: unmute in the app, or open it.
- **Bookmarks:** double-press the Bee (the single press is the Bee's own recording toggle) to mark a moment.
  It shows in the transcript and the notes are asked to cover it.
- **Event log** (Settings › Troubleshooting): button, battery, charging, state, connection, audio and app
  events, kept 60 days, exportable as CSV.
  Each change between listening and muted says who made it: from the Bee (its button), in the app, from the
  Lock Screen, or from Shortcuts or Siri. Each launch says how the app started (opened, or by iOS in the
  background for the Bee) and when it last ran before that, so a gap in the log can be told from a quiet day.
  "Connected" carries the Bee's battery and how many connection attempts failed before it; only the first
  failure of a run is logged on its own. A Bee that was already listening when it connected is noted: what it
  heard while disconnected is gone.
- **Firmware** (Your Bee): image slots, bootloader and SMP buffers, plus a note when a newer version has been
  reported (0.6.5). It only sends SMP read requests (op 0).
- **Settings:** the Bee's name, audio key, low-battery, disconnect and day's-digest alerts, transcription
  engine and model, conversation gap, voices, storage and "delete everything", TX power and bitrate behind an "untested"
  switch, the event log, forget the Bee.
- **Background:** `bluetooth-central` plus state restoration. The connection request stays pending,
  so iOS reconnects when the Bee comes back and the app logs events and captures audio while closed.
  `processing` for the overnight run. MetricKit reports (background terminations) are saved to
  `Application Support/Diagnostics` and summarized in the event log.
- **Shortcuts:** "Mute my Bee with FreeBee", "Unmute my Bee with FreeBee", "FreeBee battery".

## Verified on hardware (iPhone 17 Pro, iOS 27.0.1, Bee on 0.6.1)

- AccessorySetupKit pairing, reconnect after relaunch, events, key import, mute and unmute.
- Capture: 45 s → 368 notifications, 702 frames, 0 lost, 495-byte packets at MTU 498, audio verified in the
  first second; the segment file is valid ADTS (16 kHz mono, 32 kbps).
- Processing that capture on the phone: 28 s of speech → one conversation → Parakeet v3 transcript (one
  speaker, taken to be "Me") → Foundation Models title, summary, to-dos with quotes and the day's digest.

## Not yet verified on hardware

Everything Bluetooth-facing was written against the protocol notes and tested against the simulated
Bee, not a real one. Worth checking first on the device:

- The AccessorySetupKit sheet finds the Bee by its `0xD5C4` service and pairs it. The descriptor asks
  the picker to do LE pairing (`AccessoryPairing.supportOptions`); remove that option if setup fails.
- Mute and unmute with the imported key.
- Background reconnect after walking out of range, and after iOS terminates the app.
- Frontier battery readings are millivolts; the percentage is an estimate from a generic LiPo curve.
