"""Bee wearable BLE protocol: UUIDs, command IDs, message framing and payload decoders.

IDs and layouts come from the reverse engineering in jkmills/bee-wearable-ble (MIT) and were
checked against our own unit (legacy hardware, firmware 0.6.1). See docs/PROTOCOL.md.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum

ADVERTISED_NAME = "Bee"
ADVERTISED_SERVICE_UUID = "0000d5c4-0000-1000-8000-00805f9b34fb"
LEGACY_COMPANY_ID = 0xBEEE
FRONTIER_COMPANY_ID = 0xBEEF

CONTROL_SERVICE_UUID = "03d5d5c4-a86c-11ee-9d89-8f2089a49e7e"
CONTROL_CHAR_UUID = "05e1f93c-d8d0-5ed8-dd88-379e4c1a3e3e"  # write + notify
AUDIO_CHAR_UUID = "b189a505-a86c-11ee-a5fb-8f2089a49e7e"  # notify only
SMP_SERVICE_UUID = "8d53dc1d-1db7-4cd3-868b-8a527460aa84"  # MCUmgr (Zephyr / MCUboot)
SMP_CHAR_UUID = "da2e7828-fbce-4e01-ae9e-261174997c48"


class Cmd(IntEnum):
    SET_TX_POWER = 0xC001
    GET_TX_LEVEL = 0xC002
    GET_CHARGING_SPEED = 0xC004
    GET_FIRMWARE_VERSION = 0xC005
    SET_DEVICE_STATE = 0xC006
    SET_BITRATE = 0xC008
    GET_BITRATE = 0xC009
    GET_DEVICE_STATE = 0xC00A
    GET_DEVICE_ID = 0xC00E
    GET_BATTERY = 0xC00F
    SET_BRIGHTNESS = 0xC016
    GET_BRIGHTNESS = 0xC017
    SET_ENCRYPTION_KEY = 0xC018
    GET_SESSION_NONCE = 0xC019
    GET_SECURE_IDS = 0xC01B
    GET_DSN = 0xC01D


class Status(IntEnum):
    OK = 0x8000
    ERROR = 0x8001
    INVALID_PARAM = 0x8002
    UNKNOWN_MESSAGE = 0x8003
    KEY_ACCEPTED = 0x8004  # SetEncryptionKey re-key acknowledgement


class Event(IntEnum):
    BUTTON_DOUBLE_PRESS = 0xA001
    BUTTON_HOLD = 0xA002
    DEVICE_STATE = 0xA003
    BATTERY = 0xA004
    CHARGING = 0xA005


class DeviceState(IntEnum):
    MUTE = 0
    RECORDING = 1
    SLEEP_HW_VAD = 2
    POWER_OFF = 3
    SLEEP_SW_VAD = 4


class Codec(IntEnum):
    OPUS = 0
    AAC = 1


def _enum_or_int(enum: type[IntEnum], value: int) -> IntEnum | int:
    try:
        return enum(value)
    except ValueError:
        return value


def _name(value: IntEnum | int | None) -> str:
    if value is None:
        return "?"
    return value.name.lower() if isinstance(value, IntEnum) else str(value)


def encode(cmd: int, payload: bytes = b"") -> bytes:
    """Control-characteristic write: little-endian uint16 command id, then payload."""
    return struct.pack("<H", cmd) + payload


@dataclass(frozen=True)
class Message:
    """One control-characteristic notification from the device."""

    code: int
    command: int | None  # request id echoed back by status responses; None for events
    payload: bytes

    @property
    def is_event(self) -> bool:
        return 0xA000 <= self.code < 0xB000

    @property
    def ok(self) -> bool:
        return self.code in (Status.OK, Status.KEY_ACCEPTED)

    @property
    def name(self) -> str:
        for enum in (Status, Event):
            try:
                return enum(self.code).name
            except ValueError:
                pass
        return f"0x{self.code:04X}"


def decode(data: bytes) -> Message:
    if len(data) < 2:
        raise ValueError(f"control message too short: {data.hex()}")
    code = struct.unpack_from("<H", data)[0]
    rest = bytes(data[2:])
    if code in Status._value2member_map_ and len(rest) >= 2:
        return Message(code, struct.unpack_from("<H", rest)[0], rest[2:])
    return Message(code, None, rest)


# --- payload decoders -------------------------------------------------------


@dataclass(frozen=True)
class FirmwareVersion:
    major: int
    minor: int
    patch: int
    hw_rev: int | None = None

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @classmethod
    def parse(cls, payload: bytes) -> FirmwareVersion:
        if len(payload) < 3:
            raise ValueError("firmware version payload too short")
        return cls(payload[2], payload[1], payload[0], payload[4] if len(payload) >= 5 else None)


@dataclass(frozen=True)
class Battery:
    percent: int
    charging: bool

    @classmethod
    def parse(cls, payload: bytes) -> Battery:
        # Legacy (0xBEEE) layout. Frontier hardware reportedly uses a millivolt format instead.
        if len(payload) < 2:
            raise ValueError("battery payload too short")
        return cls(payload[0], payload[1] != 0)


def parse_device_state(payload: bytes) -> tuple[DeviceState | int, Codec | int | None]:
    if not payload:
        raise ValueError("device state payload empty")
    codec = _enum_or_int(Codec, payload[1]) if len(payload) >= 2 else None
    return _enum_or_int(DeviceState, payload[0]), codec


def format_device_id(raw: bytes) -> str:
    """Bee's device-id string: LE32 of bytes 4-7, then LE32 of bytes 0-3, as uppercase hex."""
    if len(raw) < 8:
        raise ValueError("device id needs 8 bytes")
    lo, hi = struct.unpack_from("<II", raw)
    return f"{hi:08X}{lo:08X}"


def parse_secure_ids(payload: bytes) -> tuple[str, bool | None]:
    """Returns (device_id, sealed flag)."""
    return format_device_id(payload), bool(payload[8]) if len(payload) >= 9 else None


def parse_dsn(payload: bytes) -> str:
    return payload.rstrip(b"\x00\xff").decode("ascii", errors="replace")


def describe_event(msg: Message) -> str:
    d = msg.payload
    match msg.code:
        case Event.BUTTON_DOUBLE_PRESS:
            return "button: double press"
        case Event.BUTTON_HOLD:
            return "button: hold" if d[:1] == b"\x01" else "button: release"
        case Event.DEVICE_STATE if d:
            state, codec = parse_device_state(d)
            return f"state: {_name(state)} (codec {_name(codec)})"
        case Event.BATTERY if d:
            return f"battery: {d[0]}%"
        case Event.CHARGING:
            return "charging: yes" if any(d[:1]) else "charging: no"
    return f"{msg.name}: {d.hex()}"


# --- advertisement ----------------------------------------------------------


@dataclass(frozen=True)
class Advertisement:
    device_id: str
    hardware: str  # "legacy" (0xBEEE) or "frontier" (0xBEEF)
    hw_rev: int | None = None
    bonded: bool | None = None

    @classmethod
    def parse(cls, manufacturer_data: dict[int, bytes]) -> Advertisement | None:
        if (data := manufacturer_data.get(FRONTIER_COMPANY_ID)) and len(data) >= 11 and data[8] == 1:
            return cls(format_device_id(data), "frontier", data[9], bool(data[10] & 1))
        if (data := manufacturer_data.get(LEGACY_COMPANY_ID)) and len(data) >= 8:
            return cls(format_device_id(data), "legacy")
        return None


# --- SetEncryptionKey token ---------------------------------------------------

TOKEN_MAGIC = b"SKV1"


@dataclass(frozen=True)
class SealedToken:
    """The SetEncryptionKey payload the official app sends at pairing.

    Layout: "SKV1" magic (4) | device id (8) | AES-128-CTR audio key (16) | sealed trailer (80).
    """

    raw: bytes

    @classmethod
    def parse(cls, raw: bytes) -> SealedToken:
        if raw[:4] != TOKEN_MAGIC or len(raw) < 28:
            raise ValueError("not a SKV1 SetEncryptionKey token")
        return cls(bytes(raw))

    @property
    def device_id(self) -> str:
        return format_device_id(self.raw[4:12])

    @property
    def key(self) -> bytes:
        return self.raw[12:28]
