# FreeBee

Use the Bee wearable without the Bee app or Bee/Amazon servers. The band only speaks Bluetooth
to a phone. The official app is what relays audio and events to the cloud, so replacing the app
cuts that path entirely.

- `app/FreeBee/`: FreeBee, the iPhone companion app (see its [README](app/FreeBee/README.md))
- `mac/`: `beekit`, a Python client and CLI for debugging and testing on macOS
- `docs/PROTOCOL.md`: the protocol both apps implement
- `docs/IOS_PLAN.md`: plan for the iPhone companion app (status and controls)

## Setup

```bash
cd mac
uv sync
uv run pytest
uv run beekit scan
```

Outside pairing mode the Bee only accepts the last device it paired with. To pair the Mac:
forget "Bee" in System Settings → Bluetooth, run `uv run beekit --wait 300 info`, then press the
Bee 5 times (LED flashes blue-green). Pairing another device (e.g. a phone) later bumps the Mac.

## Commands

| | |
|---|---|
| `beekit scan` | Bees advertising nearby, with device id |
| `beekit info` | firmware, battery, state, codec, brightness, bitrate, sealed flag |
| `beekit fw` | firmware image slots and bootloader (read-only SMP) |
| `beekit watch` | live button, battery, charging and state events |
| `beekit set brightness 60` / `set state sleep-hw` | change settings (`state`: mute, recording, sleep-hw, sleep-sw, off) |
| `beekit import-key capture.pklg` | extract the pairing token from an iPhone/Android Bluetooth capture |
| `beekit audio --seconds 60` | stream audio; writes `captures/*.aac` when a key is on file, raw packets always |
| `beekit decrypt captures/X-raw.jsonl` | decrypt a raw capture after the fact |

Captured audio goes to `captures/` and keys to `~/.config/beekit/secrets.json` (mode 0600). Both
stay out of version control.

## Getting the audio key (one time)

Audio is encrypted with a per-device key that Bee's backend sends to the band during pairing,
inside the `SetEncryptionKey` write. Capture that write once:

1. iPhone: install Apple's **Bluetooth logging profile**
   (developer.apple.com/bug-reporting/profiles-and-logs).
2. Mac: install **PacketLogger** from "Additional Tools for Xcode" (developer.apple.com/download/all).
3. Plug in the iPhone, then in PacketLogger choose **File → New iOS Trace**.
4. Forget "Bee" in the iPhone's Bluetooth settings, press the Bee 5 times, then in the Bee app
   choose **Upgrade to a new Bee Pioneer** and let it pair.
5. Save the trace, then run `uv run beekit import-key ~/path/to/trace.pklg`.

After that, log out of or delete the Bee app. Decline any firmware update it offers. If it forces
one, keep PacketLogger running, because the image travels over Bluetooth and ends up in the trace.

Protocol details from [jkmills/bee-wearable-ble](https://github.com/jkmills/bee-wearable-ble) (MIT).

## License

MIT, see [LICENSE](LICENSE).
