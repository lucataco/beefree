"""Async BLE client for the Bee (CoreBluetooth on macOS, via bleak)."""

from __future__ import annotations

import asyncio
import contextlib
import time
from collections.abc import AsyncIterator, Callable

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData
from bleak.exc import BleakError

from . import protocol as p
from .smp import Smp

RESPONSE_TIMEOUT_S = 5.0


class BeeNotFound(RuntimeError):
    pass


class BeeRefused(RuntimeError):
    """Advertising, but not accepting us: it only takes its last paired central outside pairing mode."""


class BeeError(RuntimeError):
    """The device answered a request with Error / InvalidParam / UnknownMessage."""

    def __init__(self, cmd: int, msg: p.Message):
        self.cmd = cmd
        self.message = msg
        name = p.Cmd(cmd).name if cmd in p.Cmd._value2member_map_ else f"0x{cmd:04X}"
        super().__init__(f"{name} -> {msg.name}")


def is_bee(_device: BLEDevice, adv: AdvertisementData) -> bool:
    return (
        p.LEGACY_COMPANY_ID in adv.manufacturer_data
        or p.FRONTIER_COMPANY_ID in adv.manufacturer_data
        or p.ADVERTISED_SERVICE_UUID in (u.lower() for u in adv.service_uuids)
    )


async def discover(timeout: float = 8.0) -> list[tuple[BLEDevice, AdvertisementData]]:
    found: dict[str, tuple[BLEDevice, AdvertisementData]] = {}

    def on_detect(device: BLEDevice, adv: AdvertisementData) -> None:
        if is_bee(device, adv):
            found[device.address] = (device, adv)

    async with BleakScanner(on_detect):
        await asyncio.sleep(timeout)
    return list(found.values())


async def find(timeout: float = 15.0) -> BLEDevice:
    device = await BleakScanner.find_device_by_filter(is_bee, timeout=timeout)
    if device is None:
        raise BeeNotFound(
            "No Bee advertising nearby. It only accepts a new central in pairing mode "
            "(5 quick button presses); a bonded Mac can connect any time it's advertising."
        )
    return device


async def _open_client(
    address: str | None,
    scan_timeout: float,
    connect_timeout: float,
    wait: float,
    on_disconnect: Callable[[BleakClient], None],
) -> BleakClient:
    deadline = time.monotonic() + wait
    while True:
        try:
            client = BleakClient(
                address or await find(scan_timeout), disconnected_callback=on_disconnect, timeout=connect_timeout
            )
            await client.connect()
            return client
        except (BeeNotFound, BleakError, KeyError):
            # bleak's CoreBluetooth backend raises KeyError if the peripheral drops mid-connect,
            # which happens while macOS (re)pairs with a Bee that just entered pairing mode.
            if time.monotonic() >= deadline:
                raise
        except TimeoutError:
            if time.monotonic() >= deadline:
                raise BeeRefused(
                    "The Bee is advertising but refused the connection: outside pairing mode it only "
                    "accepts the last device it paired with. Press its button 5 times (LED flashes "
                    "blue-green) and retry, e.g. `beekit --wait 120 info`."
                ) from None


class BeeDevice:
    """A connected Bee. Requests are serialized: one command in flight at a time."""

    def __init__(self, client: BleakClient):
        self.client = client
        self._lock = asyncio.Lock()
        self._pending: tuple[int, asyncio.Future[p.Message]] | None = None
        self._event_listeners: list[Callable[[p.Message], None]] = []
        self.unmatched: list[p.Message] = []
        self.disconnected = asyncio.Event()  # set when the link drops (Bee out of range, powered off...)

    @classmethod
    @contextlib.asynccontextmanager
    async def connect(
        cls,
        address: str | None = None,
        *,
        scan_timeout: float = 15.0,
        connect_timeout: float = 20.0,
        wait: float = 0.0,
    ) -> AsyncIterator[BeeDevice]:
        """Connect, retrying for up to `wait` seconds (e.g. while you put the Bee in pairing mode)."""
        loop = asyncio.get_running_loop()
        disconnected = asyncio.Event()
        client = await _open_client(
            address, scan_timeout, connect_timeout, wait, lambda _c: loop.call_soon_threadsafe(disconnected.set)
        )
        try:
            bee = cls(client)
            bee.disconnected = disconnected
            await client.start_notify(p.CONTROL_CHAR_UUID, bee._on_control)
            yield bee
        finally:
            await client.disconnect()

    # --- plumbing ---------------------------------------------------------------

    def _on_control(self, _char: object, data: bytearray) -> None:
        msg = p.decode(bytes(data))
        if msg.is_event:
            for listener in list(self._event_listeners):
                listener(msg)
            return
        if self._pending and not self._pending[1].done() and msg.command in (self._pending[0], None):
            self._pending[1].set_result(msg)
        else:
            self.unmatched.append(msg)

    def add_event_listener(self, listener: Callable[[p.Message], None]) -> None:
        self._event_listeners.append(listener)

    async def events(self) -> AsyncIterator[p.Message]:
        queue: asyncio.Queue[p.Message] = asyncio.Queue()
        self._event_listeners.append(queue.put_nowait)
        try:
            while True:
                yield await queue.get()
        finally:
            self._event_listeners.remove(queue.put_nowait)

    async def request(self, cmd: p.Cmd, payload: bytes = b"", timeout: float = RESPONSE_TIMEOUT_S) -> bytes:
        async with self._lock:
            future: asyncio.Future[p.Message] = asyncio.get_running_loop().create_future()
            self._pending = (cmd, future)
            try:
                await self.client.write_gatt_char(p.CONTROL_CHAR_UUID, p.encode(cmd, payload), response=True)
                msg = await asyncio.wait_for(future, timeout)
            finally:
                self._pending = None
        if not msg.ok:
            raise BeeError(cmd, msg)
        return msg.payload

    # --- reads ------------------------------------------------------------------

    async def firmware_version(self) -> p.FirmwareVersion:
        return p.FirmwareVersion.parse(await self.request(p.Cmd.GET_FIRMWARE_VERSION))

    async def battery(self) -> p.Battery:
        return p.Battery.parse(await self.request(p.Cmd.GET_BATTERY))

    async def device_state(self) -> tuple[p.DeviceState | int, p.Codec | int | None]:
        return p.parse_device_state(await self.request(p.Cmd.GET_DEVICE_STATE))

    async def device_id(self) -> str:
        return p.format_device_id(await self.request(p.Cmd.GET_DEVICE_ID))

    async def secure_ids(self) -> tuple[str, bool | None]:
        return p.parse_secure_ids(await self.request(p.Cmd.GET_SECURE_IDS))

    async def dsn(self) -> str:
        return p.parse_dsn(await self.request(p.Cmd.GET_DSN))

    async def tx_level(self) -> int:
        return (await self.request(p.Cmd.GET_TX_LEVEL))[0]

    async def bitrate(self) -> int:
        return int.from_bytes((await self.request(p.Cmd.GET_BITRATE))[:4], "little", signed=True)

    async def brightness(self) -> int:
        return (await self.request(p.Cmd.GET_BRIGHTNESS, b"\x01"))[0]

    async def session_nonce(self) -> bytes:
        return await self.request(p.Cmd.GET_SESSION_NONCE)

    # --- writes -----------------------------------------------------------------

    async def set_brightness(self, value: int) -> None:
        if not 0 <= value <= 100:
            raise ValueError("brightness must be 0-100")
        await self.request(p.Cmd.SET_BRIGHTNESS, bytes([1, value]))

    async def set_tx_power(self, power: int) -> None:
        await self.request(p.Cmd.SET_TX_POWER, power.to_bytes(1, "little", signed=True))

    async def set_bitrate(self, bitrate: int) -> None:
        await self.request(p.Cmd.SET_BITRATE, bitrate.to_bytes(4, "little", signed=True))

    async def set_state(self, state: p.DeviceState) -> None:
        """MUTE/RECORDING only stick inside an open session (see open_session)."""
        await self.request(p.Cmd.SET_DEVICE_STATE, bytes([state]))

    async def open_session(self, token: p.SealedToken) -> bytes:
        """Unlock this connection with the captured pairing token; returns the 12-byte session nonce."""
        await self.request(p.Cmd.SET_ENCRYPTION_KEY, token.raw)
        return await self.session_nonce()

    # --- audio / firmware management -------------------------------------------------

    async def start_audio(self, on_packet: Callable[[bytes], None]) -> None:
        await self.client.start_notify(p.AUDIO_CHAR_UUID, lambda _c, data: on_packet(bytes(data)))

    async def stop_audio(self) -> None:
        await self.client.stop_notify(p.AUDIO_CHAR_UUID)

    def smp(self) -> Smp:
        return Smp(self.client)
