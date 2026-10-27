"""Read-only MCUmgr/SMP queries: firmware image slots, bootloader and buffer parameters.

Only SMP *read* operations exist here on purpose. Nothing in this module can upload, erase,
test, confirm or reset firmware images.
"""

from __future__ import annotations

import asyncio
import struct
from typing import Any

import cbor2
from bleak import BleakClient

from . import protocol as p

OP_READ = 0
GROUP_OS = 0
GROUP_IMAGE = 1
OS_MCUMGR_PARAMS = 6
OS_APP_INFO = 7
OS_BOOTLOADER_INFO = 8
IMAGE_STATE = 0

RC_NAMES = {
    1: "EUNKNOWN", 2: "ENOMEM", 3: "EINVAL", 4: "ETIMEOUT", 5: "ENOENT", 6: "EBADSTATE",
    7: "EMSGSIZE", 8: "ENOTSUP", 9: "ECORRUPT", 10: "EBUSY", 11: "EACCESSDENIED",
}


class SmpError(RuntimeError):
    def __init__(self, rc: int):
        self.rc = rc
        super().__init__(f"SMP rc={rc} ({RC_NAMES.get(rc, '?')})")


class Smp:
    def __init__(self, client: BleakClient):
        self._client = client
        self._buf = bytearray()
        self._frames: asyncio.Queue[bytes] = asyncio.Queue()
        self._seq = 0

    async def __aenter__(self) -> Smp:
        await self._client.start_notify(p.SMP_CHAR_UUID, self._on_notify)
        return self

    async def __aexit__(self, *_exc: object) -> None:
        await self._client.stop_notify(p.SMP_CHAR_UUID)

    def _on_notify(self, _char: object, data: bytearray) -> None:
        # Responses can span several notifications; the 8-byte header carries the body length.
        self._buf.extend(data)
        while len(self._buf) >= 8:
            need = 8 + int.from_bytes(self._buf[2:4], "big")
            if len(self._buf) < need:
                break
            self._frames.put_nowait(bytes(self._buf[:need]))
            del self._buf[:need]

    async def read(self, group: int, command_id: int, body: dict | None = None, timeout: float = 5.0) -> Any:
        payload = cbor2.dumps(body or {})
        self._seq = seq = (self._seq + 1) & 0xFF
        header = struct.pack(">BBHHBB", OP_READ, 0, len(payload), group, seq, command_id)
        await self._client.write_gatt_char(p.SMP_CHAR_UUID, header + payload, response=False)
        while True:
            frame = await asyncio.wait_for(self._frames.get(), timeout)
            _op, _flags, length, rgroup, rseq, rid = struct.unpack_from(">BBHHBB", frame)
            if (rgroup, rseq, rid) == (group, seq, command_id):
                break
        result = cbor2.loads(frame[8 : 8 + length]) if length else {}
        if isinstance(result, dict) and result.get("rc", 0):
            raise SmpError(result["rc"])
        return result

    async def image_state(self) -> list[dict]:
        return (await self.read(GROUP_IMAGE, IMAGE_STATE)).get("images", [])

    async def bootloader(self) -> dict:
        return await self.read(GROUP_OS, OS_BOOTLOADER_INFO)

    async def params(self) -> dict:
        return await self.read(GROUP_OS, OS_MCUMGR_PARAMS)

    async def app_info(self) -> str:
        return (await self.read(GROUP_OS, OS_APP_INFO, {"format": "a"})).get("output", "")
