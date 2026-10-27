"""beekit: talk to your Bee over Bluetooth, with no phone app or cloud in the loop."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import sys
import time
from collections.abc import Awaitable
from contextlib import nullcontext, suppress
from pathlib import Path
from typing import Any

from . import hcilog, keystore
from . import protocol as p
from .audio import AudioDecoder
from .device import BeeDevice, BeeError, BeeNotFound, BeeRefused, discover
from .smp import SmpError

NEWEST_PUBLIC_FIRMWARE = (0, 6, 5)  # newest build reported publicly (jkmills/bee-wearable-ble)
STATES = {
    "mute": p.DeviceState.MUTE,
    "recording": p.DeviceState.RECORDING,
    "sleep-hw": p.DeviceState.SLEEP_HW_VAD,
    "sleep-sw": p.DeviceState.SLEEP_SW_VAD,
    "off": p.DeviceState.POWER_OFF,
}


async def _try(awaitable: Awaitable[Any]) -> Any:
    try:
        return await awaitable
    except (BeeError, SmpError, asyncio.TimeoutError) as e:
        return f"<{e.__class__.__name__}: {e}>"


def _fingerprint(key: bytes) -> str:
    return hashlib.sha256(key).hexdigest()[:12]


def _show(data: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(data, indent=2, default=str))
    else:
        width = max(map(len, data))
        for k, v in data.items():
            print(f"{k:<{width}}  {v}")


async def cmd_scan(args: argparse.Namespace) -> int:
    found = await discover(args.seconds)
    if not found:
        print("No Bee advertising nearby.")
        return 1
    for device, adv in sorted(found, key=lambda f: -(f[1].rssi or -999)):
        info = p.Advertisement.parse(adv.manufacturer_data)
        extra = f" hw_rev={info.hw_rev} bonded={info.bonded}" if info and info.hardware == "frontier" else ""
        print(
            f"{device.address}  rssi={adv.rssi}  name={adv.local_name or device.name}  "
            f"id={info.device_id if info else '?'}  hardware={info.hardware if info else '?'}{extra}"
        )
    return 0


async def cmd_info(args: argparse.Namespace) -> int:
    async with BeeDevice.connect(args.address, wait=args.wait) as bee:
        fw = await bee.firmware_version()
        battery = await bee.battery()
        state, codec = await bee.device_state()
        device_id, sealed = await bee.secure_ids()
        info = {
            "address": bee.client.address,
            "device_id": device_id,
            "firmware": str(fw) + (f" (hw rev {fw.hw_rev})" if fw.hw_rev is not None else ""),
            "battery": f"{battery.percent}%{' charging' if battery.charging else ''}",
            "state": getattr(state, "name", state),
            "codec": getattr(codec, "name", codec),
            "brightness": await _try(bee.brightness()),
            "tx_level": await _try(bee.tx_level()),
            "bitrate": await _try(bee.bitrate()),
            "sealed": sealed,
            "dsn": await _try(bee.dsn()),
            "key_on_file": "yes" if keystore.load(device_id) else "no (run `beekit import-key`)",
        }
    _show(info, args.json)
    return 0


async def cmd_fw(args: argparse.Namespace) -> int:
    async with BeeDevice.connect(args.address, wait=args.wait) as bee:
        fw = await bee.firmware_version()
        async with bee.smp() as smp:
            images = await _try(smp.image_state())
            boot = await _try(smp.bootloader())
            params = await _try(smp.params())
            app = await _try(smp.app_info())
    if args.json:
        _show({"firmware": str(fw), "images": images, "bootloader": boot, "params": params, "app_info": app}, True)
        return 0
    print(f"running firmware   {fw}")
    newest = ".".join(map(str, NEWEST_PUBLIC_FIRMWARE))
    if (fw.major, fw.minor, fw.patch) < NEWEST_PUBLIC_FIRMWARE:
        print(f"                   older than {newest}, the newest build reported publicly")
    for img in images if isinstance(images, list) else []:
        flags = ",".join(k for k in ("active", "confirmed", "pending", "permanent", "bootable") if img.get(k))
        digest = img.get("hash", b"")
        digest = digest.hex() if isinstance(digest, bytes) else str(digest)
        print(f"slot {img.get('slot')}             {img.get('version')}  [{flags}]  sha256 {digest[:16]}...")
    print(f"bootloader         {boot.get('bootloader') if isinstance(boot, dict) else boot}")
    print(f"os/app info        {app or '<empty>'}")
    print(f"smp buffers        {params}")
    return 0


async def cmd_watch(args: argparse.Namespace) -> int:
    async with BeeDevice.connect(args.address, wait=args.wait) as bee:
        print(f"Connected to {bee.client.address}. Watching events ({'Ctrl-C to stop' if not args.seconds else f'{args.seconds:.0f}s'})...")
        with suppress(TimeoutError):
            async with asyncio.timeout(args.seconds):
                async for msg in bee.events():
                    print(f"{time.strftime('%H:%M:%S')}  {p.describe_event(msg)}", flush=True)
    return 0


async def cmd_set(args: argparse.Namespace) -> int:
    async with BeeDevice.connect(args.address, wait=args.wait) as bee:
        if args.setting == "brightness":
            await bee.set_brightness(int(args.value))
            print(f"brightness -> {await bee.brightness()}")
        elif args.setting == "tx-power":
            await bee.set_tx_power(int(args.value))
            print(f"tx level -> {await bee.tx_level()}")
        elif args.setting == "bitrate":
            await bee.set_bitrate(int(args.value))
            print(f"bitrate -> {await bee.bitrate()}")
        elif args.setting == "state":
            target = STATES[args.value]
            if target in (p.DeviceState.MUTE, p.DeviceState.RECORDING):
                secret = keystore.load(await bee.device_id())
                if secret:
                    await bee.open_session(secret.token)
                else:
                    print("note: no captured key on file; mute/recording ACK but don't stick without a session")
            await bee.set_state(target)
            if target is not p.DeviceState.POWER_OFF:
                state, _ = await bee.device_state()
                print(f"state -> {getattr(state, 'name', state)}")
    return 0


async def cmd_import_key(args: argparse.Namespace) -> int:
    hits = hcilog.find_key_tokens(args.capture)
    if not hits:
        magic = hcilog.count_magic(args.capture)
        print(f"No SetEncryptionKey write found in {args.capture}.")
        if magic:
            print(f"(The raw bytes 'SKV1' appear {magic}x, so the parser missed a framing case; worth debugging.)")
        else:
            print("Make sure the capture spans a fresh pairing (forget + 5 presses + 'Upgrade to a new Bee Pioneer').")
        return 1
    distinct = {h.token.raw for h in hits}
    print(f"Found {len(hits)} SetEncryptionKey write(s), {len(distinct)} distinct token(s).")
    for h in hits:
        print(f"  t={h.timestamp:.3f} conn=0x{h.connection:03X} att=0x{h.att_handle:04X} "
              f"device={h.token.device_id} key#{_fingerprint(h.token.key)} len={len(h.token.raw)}")
    token = hits[-1].token  # the most recent pairing wins
    path = keystore.save(token, source=str(Path(args.capture).resolve()))
    print(f"Saved token for device {token.device_id} (key #{_fingerprint(token.key)}) to {path}")
    return 0


async def cmd_audio(args: argparse.Namespace) -> int:
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    async with BeeDevice.connect(args.address, wait=args.wait) as bee:
        device_id = await bee.device_id()
        secret = None if args.raw else keystore.load(device_id)
        decoder = None
        if secret:
            nonce = await bee.open_session(secret.token)
            decoder = AudioDecoder(secret.token.key, nonce)
            print(f"Session open (key #{_fingerprint(secret.token.key)}, nonce {nonce.hex()})")
            if args.unmute:
                await bee.set_state(p.DeviceState.RECORDING)
        else:
            nonce = await _try(bee.session_nonce())
            nonce = nonce if isinstance(nonce, bytes) else b""
            print("No key on file: saving encrypted packets only (decrypt later with `beekit decrypt`).")
        state, codec = await bee.device_state()
        print(f"Device state {getattr(state, 'name', state)}, codec {getattr(codec, 'name', codec)}")
        bee.add_event_listener(lambda m: print(f"  event  {p.describe_event(m)}", flush=True))

        raw_path = out_dir / f"{stamp}-raw.jsonl"
        audio_path = out_dir / f"{stamp}.{'aac' if codec == p.Codec.AAC else 'bin'}"
        header = {"device_id": device_id, "nonce": nonce.hex(), "codec": int(codec or 0), "started": stamp}
        with raw_path.open("w") as raw_f, (audio_path.open("wb") if decoder else nullcontext()) as audio_f:
            raw_f.write(json.dumps(header) + "\n")
            stats = {"packets": 0, "bytes": 0}

            def on_packet(packet: bytes) -> None:
                stats["packets"] += 1
                stats["bytes"] += len(packet)
                raw_f.write(json.dumps({"t": round(time.time(), 3), "hex": packet.hex()}) + "\n")
                if decoder is None:
                    return
                if codec == p.Codec.AAC:
                    for frame in decoder.feed(packet):
                        audio_f.write(frame)
                else:
                    audio_f.write(decoder.decrypt(packet))

            await bee.start_audio(on_packet)
            print(f"Listening{f' for {args.seconds:.0f}s' if args.seconds else ''}; speak near the Bee. Ctrl-C to stop.")
            started = time.monotonic()
            try:
                while not args.seconds or time.monotonic() - started < args.seconds:
                    await asyncio.sleep(5)
                    print(f"  {time.monotonic() - started:4.0f}s  {stats['packets']} packets", flush=True)
            finally:
                with suppress(Exception):
                    await bee.stop_audio()
                print(f"{stats['packets']} packets ({stats['bytes']} bytes) -> {raw_path}")
                if decoder:
                    print(f"{decoder.frames} frames, {decoder.lost_packets} lost packets, "
                          f"{decoder.resync_bytes} resync bytes -> {audio_path}")
    return 0


async def cmd_decrypt(args: argparse.Namespace) -> int:
    lines = Path(args.raw).read_text().splitlines()
    header = json.loads(lines[0])
    secret = keystore.load(header["device_id"])
    if not secret:
        print(f"No key on file for device {header['device_id']}; run `beekit import-key` first.")
        return 1
    nonce = bytes.fromhex(header["nonce"])
    if len(nonce) != 12 or not any(nonce):
        print("warning: this capture has no session nonce, so decryption will probably be noise")
        nonce = nonce.ljust(12, b"\x00")[:12]
    decoder = AudioDecoder(secret.token.key, nonce)
    out = Path(args.raw).with_name(Path(args.raw).name.replace("-raw.jsonl", ".aac"))
    with out.open("wb") as f:
        for line in lines[1:]:
            for frame in decoder.feed(bytes.fromhex(json.loads(line)["hex"])):
                f.write(frame)
    print(f"{decoder.packets} packets -> {decoder.frames} frames -> {out}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="beekit", description=__doc__)
    parser.add_argument("--address", help="CoreBluetooth UUID of the Bee (default: first one found)")
    parser.add_argument("--wait", type=float, default=0, metavar="SECONDS",
                        help="keep retrying the connection this long (use while entering pairing mode)")
    sub = parser.add_subparsers(required=True, metavar="command")

    s = sub.add_parser("scan", help="list Bees advertising nearby")
    s.add_argument("--seconds", type=float, default=6)
    s.set_defaults(func=cmd_scan)

    s = sub.add_parser("info", help="firmware, battery, state and settings")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_info)

    s = sub.add_parser("fw", help="firmware image slots and bootloader (read-only SMP)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_fw)

    s = sub.add_parser("watch", help="print button, battery, charging and state events")
    s.add_argument("--seconds", type=float)
    s.set_defaults(func=cmd_watch)

    s = sub.add_parser("set", help="change a setting")
    s.add_argument("setting", choices=["brightness", "tx-power", "bitrate", "state"])
    s.add_argument("value", help=f"number, or for state: {', '.join(STATES)}")
    s.set_defaults(func=cmd_set)

    s = sub.add_parser("import-key", help="pull the pairing token out of a .pklg/btsnoop capture")
    s.add_argument("capture", type=Path)
    s.set_defaults(func=cmd_import_key)

    s = sub.add_parser("audio", help="stream audio; decrypts to .aac when a key is on file")
    s.add_argument("--seconds", type=float)
    s.add_argument("--out-dir", default="captures")
    s.add_argument("--raw", action="store_true", help="skip the session, only save encrypted packets")
    s.add_argument("--unmute", action="store_true", help="set state to RECORDING after opening the session")
    s.set_defaults(func=cmd_audio)

    s = sub.add_parser("decrypt", help="decrypt a saved *-raw.jsonl capture to .aac")
    s.add_argument("raw", type=Path)
    s.set_defaults(func=cmd_decrypt)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.func is cmd_set and args.setting == "state" and args.value not in STATES:
        print(f"state must be one of: {', '.join(STATES)}", file=sys.stderr)
        return 2
    try:
        return asyncio.run(args.func(args))
    except (BeeNotFound, BeeRefused) as e:
        print(e, file=sys.stderr)
        return 2
    except BeeError as e:
        print(f"device rejected the request: {e}", file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
