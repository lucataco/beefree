# iPhone companion app: plan

A native SwiftUI app that controls the Bee and shows its status. It's built from
[`PROTOCOL.md`](PROTOCOL.md), which is confirmed on our unit (legacy hardware `0xBEEE`, firmware 0.6.1).
No account or server is involved.

## Core features (first version)

| Feature | What it shows or does | Protocol behind it |
|---|---|---|
| **Pair and connect** | Finds the Bee, walks you through pairing mode (5 presses, LED flashes blue-green), reconnects automatically, shows signal strength | Advertised company ID `0xBEEE` / `0xBEEF`, service `0xD5C4`, then the control service `03d5d5c4-…` |
| **Status dashboard** | Battery %, charging, firmware version, device ID, current state (muted, listening, sleeping), brightness | `GetBattery` `C00F`, `GetFirmwareVersion` `C005`, `GetDeviceID` `C00E`, `GetDeviceState` `C00A`, `GetBrightness` `C017` |
| **Controls** | Mute/unmute, brightness slider (0–100), sleep modes, power off (with a confirmation) | `SetDeviceState` `C006`, `SetBrightness` `C016` |
| **Event log** | Timestamped button presses (double press, hold), battery changes, charging, state changes | Events `A001`–`A005` |
| **Firmware info** | Installed version, the backup slot, the bootloader, and a "newer version exists" flag | Read-only SMP queries (image state, bootloader info), as in `beekit fw` |
| **Key import** | Loads the captured key once and stores it in the Keychain. Mute/unmute needs it. | `~/.config/beekit/secrets.json` sent from the Mac via AirDrop |

## Nice to have later

- **Alerts:** a local notification when the battery is low or the Bee disconnects.
- **Home Screen widget:** battery level and current state.
- **Shortcuts / Siri:** for example, "Mute my Bee".
- **Settings:** TX power (`C001`) and bitrate (`C008`). They're in the protocol but untested for writes, so they belong behind an "advanced" screen.

## How it would be built

- **Protocol layer:** a pure Swift port of `mac/src/beekit/protocol.py` (framing, command IDs, decoders), with no Bluetooth code in it. It gets the same tests as `mac/tests/test_protocol.py`, using the real response bytes from our Bee.
- **Device layer:** a wrapper around Apple's Bluetooth framework (CoreBluetooth), sending one request at a time and using Swift's async/await. It's the same design as `device.py`. Write-with-response on the control characteristic; route responses by the echoed command ID.
- **Pairing:** prefer **AccessorySetupKit**, Apple's newer accessory-pairing system that the official Bee app appears to use. It gives a system pairing sheet and doesn't need broad Bluetooth permission. Plain CoreBluetooth access is the fallback.
- **Background:** iOS `bluetooth-central` background mode plus state restoration, so it reconnects and logs events while the app is closed.
- **Storage:** the key goes in the Keychain. The event history can live locally, in SwiftData or a small file.
- **Firmware queries:** SMP replies are CBOR, so this needs a small CBOR decoder. It's a small package or about 100 lines of code. Send read operations only (op 0).

## Constraints to plan around

- **One paired device at a time.** Outside pairing mode the Bee only accepts the last device it paired with. Switching between the iPhone and the Mac takes a 5-press re-pair each time. Making the iPhone the main device and the Mac the debugging tool is the simplest arrangement.
- **Mute/unmute needs the key.** Mute and recording only stick inside a session opened with `SetEncryptionKey`. Everything else works without the key.
- **Hardware variants:** newer "Frontier" Bees use ID `0xBEEF`, add a hardware revision and a bonded flag to the advertisement, and report battery differently. Support both in the parser even though ours is the older model.
- **Firmware updates could change behaviour.** That's another reason to stay on 0.6.1 for now; the newest version reported publicly is 0.6.5.

## Milestones

1. Swift protocol package and its tests, which needs no device.
2. Scan, pair, connect and the status dashboard.
3. Controls and the event log.
4. Key import, which enables mute/unmute.
5. The firmware info screen.
6. Background reconnect, alerts and the widget.
