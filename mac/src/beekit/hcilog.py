"""Extract the Bee's SetEncryptionKey token from a Bluetooth HCI capture.

Reads Apple PacketLogger captures (.pklg, e.g. an iPhone traced with the iOS Bluetooth logging
profile) and btsnoop files (Android HCI snoop log, or PacketLogger's btsnoop export).
Reassembles ACL -> L2CAP -> ATT and looks for writes that start with 0xC018 + "SKV1".
"""

from __future__ import annotations

import struct
import tarfile
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path

from . import protocol as p

PKLG_ACL_SENT = 0x02
PKLG_ACL_RECV = 0x03
BTSNOOP_MAGIC = b"btsnoop\x00"
BTSNOOP_HCI_UNENCAP = 1001
BTSNOOP_HCI_UART = 1002
H4_ACL = 0x02
ATT_CID = 0x0004
ATT_WRITE_REQ = 0x12
ATT_WRITE_CMD = 0x52
ATT_PREPARE_WRITE_REQ = 0x16
ATT_EXECUTE_WRITE_REQ = 0x18
SET_KEY_PREFIX = p.encode(p.Cmd.SET_ENCRYPTION_KEY) + p.TOKEN_MAGIC


@dataclass(frozen=True)
class AclPacket:
    timestamp: float
    sent: bool  # host -> controller (i.e. written by the phone/Mac that made the capture)
    data: bytes  # HCI ACL packet starting at the handle field


@dataclass(frozen=True)
class TokenHit:
    timestamp: float
    connection: int
    att_handle: int
    token: p.SealedToken


def read_pklg(blob: bytes) -> Iterator[AclPacket]:
    # Record: length(4) ts_secs(4) ts_usecs(4) type(1) data; length counts everything after itself.
    # Older files are big-endian, newer ones little-endian; pick whichever gives a sane first length.
    fmt = ">III" if 9 <= int.from_bytes(blob[:4], "big") <= 0xFFFF else "<III"
    offset = 0
    while offset + 13 <= len(blob):
        length, secs, usecs = struct.unpack_from(fmt, blob, offset)
        if length < 9 or offset + 4 + length > len(blob):
            break
        kind = blob[offset + 12]
        data = blob[offset + 13 : offset + 4 + length]
        offset += 4 + length
        if kind in (PKLG_ACL_SENT, PKLG_ACL_RECV):
            yield AclPacket(secs + usecs / 1e6, kind == PKLG_ACL_SENT, data)


def read_btsnoop(blob: bytes) -> Iterator[AclPacket]:
    _version, datalink = struct.unpack_from(">II", blob, 8)
    offset = 16
    while offset + 24 <= len(blob):
        _orig_len, incl_len, flags, _drops, ts = struct.unpack_from(">IIIIq", blob, offset)
        data = blob[offset + 24 : offset + 24 + incl_len]
        offset += 24 + incl_len
        if datalink == BTSNOOP_HCI_UART:
            if data[:1] != bytes([H4_ACL]):
                continue
            data = data[1:]
        elif datalink != BTSNOOP_HCI_UNENCAP or flags & 0x02:
            continue
        yield AclPacket(ts / 1e6, not flags & 0x01, data)


def read_capture(blob: bytes) -> Iterator[AclPacket]:
    return read_btsnoop(blob) if blob.startswith(BTSNOOP_MAGIC) else read_pklg(blob)


def capture_blobs(path: Path) -> Iterator[tuple[str, bytes]]:
    """The capture itself, or every .pklg inside an iPhone sysdiagnose archive (read in memory)."""
    path = Path(path)
    if tarfile.is_tarfile(path):
        with tarfile.open(path) as archive:
            for member in archive:
                if member.isfile() and member.name.endswith(".pklg"):
                    yield member.name, archive.extractfile(member).read()
    else:
        yield path.name, path.read_bytes()


def l2cap_frames(packets: Iterable[AclPacket]) -> Iterator[tuple[float, bool, int, int, bytes]]:
    """Yields (timestamp, sent, connection handle, channel id, payload) per reassembled L2CAP frame."""
    partial: dict[tuple[bool, int], bytearray] = {}
    for pkt in packets:
        if len(pkt.data) < 4:
            continue
        handle_flags, length = struct.unpack_from("<HH", pkt.data)
        handle, boundary = handle_flags & 0x0FFF, (handle_flags >> 12) & 0x3
        fragment = pkt.data[4 : 4 + length]
        key = (pkt.sent, handle)
        if boundary in (0b00, 0b10):  # first fragment
            partial[key] = bytearray(fragment)
        elif boundary == 0b01 and key in partial:  # continuation
            partial[key].extend(fragment)
        else:
            continue
        buf = partial[key]
        if len(buf) >= 4:
            l2_len, cid = struct.unpack_from("<HH", buf)
            if len(buf) >= 4 + l2_len:
                yield pkt.timestamp, pkt.sent, handle, cid, bytes(buf[4 : 4 + l2_len])
                del partial[key]


def att_writes(frames: Iterable[tuple[float, bool, int, int, bytes]]) -> Iterator[tuple[float, int, int, bytes]]:
    """Yields (timestamp, connection handle, attribute handle, value), including long (prepared) writes."""
    prepared: dict[tuple[bool, int], dict[int, bytearray]] = {}
    for ts, sent, conn, cid, pdu in frames:
        if cid != ATT_CID or not pdu:
            continue
        op = pdu[0]
        if op in (ATT_WRITE_REQ, ATT_WRITE_CMD) and len(pdu) >= 3:
            yield ts, conn, struct.unpack_from("<H", pdu, 1)[0], pdu[3:]
        elif op == ATT_PREPARE_WRITE_REQ and len(pdu) >= 5:
            attr, value_offset = struct.unpack_from("<HH", pdu, 1)
            buf = prepared.setdefault((sent, conn), {}).setdefault(attr, bytearray())
            buf[value_offset : value_offset + len(pdu) - 5] = pdu[5:]
        elif op == ATT_EXECUTE_WRITE_REQ and len(pdu) >= 2:
            pending = prepared.pop((sent, conn), {})
            if pdu[1] == 0x01:
                for attr, buf in pending.items():
                    yield ts, conn, attr, bytes(buf)


def find_key_tokens(path: Path) -> list[TokenHit]:
    hits = []
    for _name, blob in capture_blobs(path):
        for ts, conn, attr, value in att_writes(l2cap_frames(read_capture(blob))):
            if value.startswith(SET_KEY_PREFIX):
                hits.append(TokenHit(ts, conn, attr, p.SealedToken.parse(value[2:])))
    return sorted(hits, key=lambda h: h.timestamp)


def count_magic(path: Path) -> int:
    """Raw "SKV1" occurrences in the capture(s), for diagnosing parse failures."""
    return sum(blob.count(p.TOKEN_MAGIC) for _name, blob in capture_blobs(path))
