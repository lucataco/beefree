"""Audio-characteristic decryption (AES-128-CTR) and ADTS/AAC frame reassembly.

Each notification is [4-byte big-endian sequence number][ciphertext]. The CTR IV is
session_nonce (12 bytes) || sequence number (4 bytes), so every packet decrypts on its own.
The plaintext stream is ADTS-framed AAC (16 kHz mono on our unit's codec setting).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ADTS_SAMPLE_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)


def decrypt_packet(key: bytes, nonce: bytes, packet: bytes) -> tuple[int, bytes]:
    """Returns (sequence number, plaintext)."""
    if len(key) != 16 or len(nonce) != 12:
        raise ValueError("need a 16-byte key and a 12-byte session nonce")
    if len(packet) < 4:
        raise ValueError("audio packet shorter than its sequence number")
    decryptor = Cipher(algorithms.AES(key), modes.CTR(nonce + packet[:4])).decryptor()
    return int.from_bytes(packet[:4], "big"), decryptor.update(packet[4:]) + decryptor.finalize()


def adts_sample_rate(frame: bytes) -> int:
    index = (frame[2] >> 2) & 0x0F
    return ADTS_SAMPLE_RATES[index] if index < len(ADTS_SAMPLE_RATES) else 0


class AdtsReassembler:
    """Buffers plaintext and yields complete ADTS frames (header included).

    The official app drops the first 3 frames of every stream; skip_frames mirrors that.
    """

    def __init__(self, skip_frames: int = 3):
        self._buf = bytearray()
        self._skip = skip_frames
        self.resync_bytes = 0

    def feed(self, data: bytes) -> list[bytes]:
        self._buf.extend(data)
        frames = []
        while (frame := self._next_frame()) is not None:
            if self._skip:
                self._skip -= 1
            else:
                frames.append(frame)
        return frames

    def _next_frame(self) -> bytes | None:
        buf = self._buf
        while True:
            start = next((i for i in range(len(buf) - 1) if buf[i] == 0xFF and buf[i + 1] & 0xF0 == 0xF0), None)
            if start is None:
                keep = 1 if buf[-1:] == b"\xff" else 0  # a sync word may straddle the next packet
                self.resync_bytes += len(buf) - keep
                del buf[: len(buf) - keep]
                return None
            if start:
                self.resync_bytes += start
                del buf[:start]
            if len(buf) < 7:
                return None
            header_len = 7 if buf[1] & 0x01 else 9
            length = ((buf[3] & 0x03) << 11) | (buf[4] << 3) | (buf[5] >> 5)
            if length < header_len:
                # False sync word: skip it and keep scanning.
                self.resync_bytes += 1
                del buf[:1]
                continue
            if len(buf) < length:
                return None
            frame = bytes(buf[:length])
            del buf[:length]
            return frame


@dataclass
class AudioDecoder:
    key: bytes
    nonce: bytes
    skip_frames: int = 3
    packets: int = 0
    frames: int = 0
    lost_packets: int = 0
    _last_seq: int | None = None
    _adts: AdtsReassembler = field(init=False)

    def __post_init__(self) -> None:
        self._adts = AdtsReassembler(self.skip_frames)

    def decrypt(self, packet: bytes) -> bytes:
        seq, plaintext = decrypt_packet(self.key, self.nonce, packet)
        if self._last_seq is not None and seq > self._last_seq + 1:
            self.lost_packets += seq - self._last_seq - 1
        self._last_seq = seq
        self.packets += 1
        return plaintext

    def feed(self, packet: bytes) -> list[bytes]:
        frames = self._adts.feed(self.decrypt(packet))
        self.frames += len(frames)
        return frames

    @property
    def resync_bytes(self) -> int:
        return self._adts.resync_bytes
