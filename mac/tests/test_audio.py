import os

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from beekit.audio import AdtsReassembler, AudioDecoder, adts_sample_rate

KEY = os.urandom(16)
NONCE = os.urandom(12)


def adts_frame(payload_len: int, fill: int) -> bytes:
    length = 7 + payload_len
    header = bytes([
        0xFF, 0xF1,  # sync, MPEG-4, no CRC
        (1 << 6) | (8 << 2),  # AAC LC, 16 kHz
        (1 << 6) | (length >> 11),  # mono
        (length >> 3) & 0xFF,
        ((length & 0x7) << 5) | 0x1F,
        0xFC,
    ])
    return header + bytes([fill]) * payload_len


def encrypt_packets(stream: bytes, chunk: int, first_seq: int = 0) -> list[bytes]:
    packets = []
    for i, start in enumerate(range(0, len(stream), chunk)):
        seq = (first_seq + i).to_bytes(4, "big")
        enc = Cipher(algorithms.AES(KEY), modes.CTR(NONCE + seq)).encryptor()
        packets.append(seq + enc.update(stream[start : start + chunk]) + enc.finalize())
    return packets


def test_decrypt_and_reassemble_across_packet_boundaries():
    frames = [adts_frame(40 + i, i + 1) for i in range(8)]
    decoder = AudioDecoder(KEY, NONCE, skip_frames=3)
    out = []
    for packet in encrypt_packets(b"".join(frames), chunk=37):
        out.extend(decoder.feed(packet))
    assert out == frames[3:]
    assert decoder.lost_packets == 0
    assert adts_sample_rate(out[0]) == 16000


def test_counts_sequence_gaps():
    packets = encrypt_packets(adts_frame(100, 1) * 4, chunk=50)
    decoder = AudioDecoder(KEY, NONCE, skip_frames=0)
    for packet in packets[:2] + packets[4:]:
        decoder.feed(packet)
    assert decoder.lost_packets == 2


def test_resyncs_after_garbage_and_false_sync():
    frame = adts_frame(30, 7)
    reassembler = AdtsReassembler(skip_frames=0)
    out = reassembler.feed(b"\x00\x12\xff\xf1\x00\x00\x00\x00\x00" + frame)
    assert out == [frame]
    assert reassembler.resync_bytes > 0
