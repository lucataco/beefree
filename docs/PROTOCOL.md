# Bee BLE protocol (what beekit implements)

Shared reference for the Mac (`mac/`) and iPhone apps. Derived from the reverse engineering in
[jkmills/bee-wearable-ble](https://github.com/jkmills/bee-wearable-ble) (MIT). Items marked **✓ ours**
were confirmed against our unit: legacy hardware (`0xBEEE`), firmware 0.6.1, MCUboot.

## Discovery and pairing

| | |
|---|---|
| Name | `Bee` |
| Advertised service | 16-bit `0xD5C4` (the 128-bit control service is only visible after connecting) |
| Manufacturer data | company `0xBEEE` (legacy): 8-byte device id. `0xBEEF` (Frontier): id + `0x01` + hw rev + bonded flag |
| Device id string | `LE32(bytes 4..7)` then `LE32(bytes 0..3)` as 16 uppercase hex digits, the same value `GetDeviceID` returns ✓ ours |

While disconnected the Bee advertises only for its last central. A new central can connect only
in **pairing mode** (5 quick button presses, LED flashes blue-green) ✓ ours. The OS bonds on that
first connection and later connections work without pairing mode.

## GATT

| UUID | Properties | Use |
|---|---|---|
| `03d5d5c4-a86c-11ee-9d89-8f2089a49e7e` | service | control service |
| `05e1f93c-d8d0-5ed8-dd88-379e4c1a3e3e` | write, write-no-rsp, notify | control channel ✓ ours |
| `b189a505-a86c-11ee-a5fb-8f2089a49e7e` | notify | encrypted audio ✓ ours |
| `8d53dc1d-1db7-4cd3-868b-8a527460aa84` | service | MCUmgr SMP (firmware management) ✓ ours |
| `da2e7828-fbce-4e01-ae9e-261174997c48` | write-no-rsp, notify | SMP channel ✓ ours |

MTU negotiated on macOS: 498 ✓ ours. Use write-with-response on the control channel, one
request in flight at a time.

## Control channel framing

Every message, both directions: `uint16 LE code` + payload.

Responses: `0x8000` OK, `0x8001` Error, `0x8002` InvalidParam, `0x8003` UnknownMessage,
`0x8004` key accepted (re-key). Status responses start their payload with the **echoed request
command id** (LE16), then the response data. Example: `00 80 05 C0 01 06 00` = OK for
GetFirmwareVersion, data `01 06 00` = 0.6.1 ✓ ours.

| Command | ID | Request | Response data |
|---|---|---|---|
| SetTxPower | `C001` | int8 | |
| GetTxLevel | `C002` | | uint8 (ours: 8) |
| GetFirmwareVersion | `C005` | | `[patch, minor, major, ?, hw_rev?]` ✓ ours |
| SetDeviceState | `C006` | uint8 state | uint8 |
| SetBitrate | `C008` | int32 LE | |
| GetBitrate | `C009` | | int32 LE (ours: 32000) ✓ ours |
| GetDeviceState | `C00A` | | `[state, codec]` ✓ ours |
| GetDeviceID | `C00E` | | 8 raw id bytes ✓ ours |
| GetBattery | `C00F` | | legacy: `[percent, charging]` ✓ ours |
| SetBrightness | `C016` | `[1, 0..100]` | |
| GetBrightness | `C017` | `[1]` | uint8 |
| SetEncryptionKey | `C018` | sealed token (below) | OK, or `0x8004` on re-key |
| GetSessionNonce | `C019` | | 12 bytes |
| GetSecureIds | `C01B` | | 8 id bytes + sealed flag (ours: 0) ✓ ours |
| GetDSN | `C01D` | | ASCII; UnknownMessage on legacy ✓ ours |

States: 0 mute, 1 recording, 2 sleep (hardware VAD), 3 power off, 4 sleep (software VAD).
Codecs: 0 Opus, 1 AAC. Mute and recording only stick inside an open session; the others work without one.

Events (device → phone, no echoed id): `A001` double press, `A002` hold (`1` pressed / `0`
released), `A003` state `[state, codec]`, `A004` battery `[percent]`, `A005` charging `[0/1]` ✓ ours.

## Session and audio

1. `SetEncryptionKey(token)`. The token is what the official app sends at pairing (Bee's backend issues
   it per device): `"SKV1"` (4) + device id (8) + **AES-128 key** (16) + sealed trailer (80) = 108 bytes.
   The first SetEncryptionKey of a connection must be the device's current real token.
2. `GetSessionNonce` → 12-byte nonce (new every connection).
3. Subscribe to the audio characteristic. Each notification is `uint32 BE seq` + AES-128-CTR
   ciphertext, IV = `nonce || seq`. No auth tag. Plaintext is ADTS-framed AAC (16 kHz);
   the official app discards the first 3 frames.

✓ ours (2026-10-20): token captured from an iPhone sysdiagnose, session opened from the Mac,
45 s capture = 366 packets → 698 ADTS frames, 0 lost, 0 resync bytes, 16 kHz mono ~32 kbps.
The token survived putting the Bee back in pairing mode to pair the Mac afterwards.

A self-generated key can be spliced into the token after the real one unlocks the connection.
Control commands then work with that key, but audio keeps using the real one. So capture the real
token once (see README).

## SMP (read-only use)

Standard MCUmgr: 8-byte header `op, flags, len (BE16), group (BE16), seq, id` + CBOR body.
On our unit: image state lists slot 0 = 0.6.1 (active, confirmed) and slot 1 = 0.5.0 (bootable);
bootloader info returns `MCUboot`; OS app info returns ENOTSUP; params `buf_size 2475, buf_count 4`.
beekit only sends read ops (op 0).
