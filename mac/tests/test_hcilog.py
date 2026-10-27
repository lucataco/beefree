import struct

from beekit import hcilog
from beekit import protocol as p

TOKEN = b"SKV1" + bytes.fromhex("0102030405060708") + bytes(range(16)) + bytes(80)
CONN = 0x0040
ATT_HANDLE = 0x0012


def att_write(value: bytes) -> bytes:
    att = bytes([hcilog.ATT_WRITE_REQ]) + struct.pack("<H", ATT_HANDLE) + value
    return struct.pack("<HH", len(att), hcilog.ATT_CID) + att


def acl(l2cap: bytes, fragment: int = 0) -> list[bytes]:
    size = fragment or len(l2cap)
    chunks = [l2cap[i : i + size] for i in range(0, len(l2cap), size)]
    return [
        struct.pack("<HH", CONN | ((0b00 if i == 0 else 0b01) << 12), len(c)) + c for i, c in enumerate(chunks)
    ]


def pklg(packets: list[bytes], big_endian: bool = True) -> bytes:
    fmt = ">III" if big_endian else "<III"
    out = b""
    for i, data in enumerate(packets):
        body_len = 8 + 1 + len(data)
        out += struct.pack(fmt, body_len, 1_700_000_000 + i, 0) + bytes([hcilog.PKLG_ACL_SENT]) + data
    return out


def btsnoop(packets: list[bytes]) -> bytes:
    out = hcilog.BTSNOOP_MAGIC + struct.pack(">II", 1, hcilog.BTSNOOP_HCI_UART)
    for data in packets:
        rec = bytes([hcilog.H4_ACL]) + data
        out += struct.pack(">IIIIq", len(rec), len(rec), 0, 0, 0) + rec
    return out


def extract(tmp_path, blob: bytes) -> list[hcilog.TokenHit]:
    path = tmp_path / "capture"
    path.write_bytes(blob)
    return hcilog.find_key_tokens(path)


def test_pklg_single_packet(tmp_path):
    noise = acl(att_write(p.encode(p.Cmd.GET_FIRMWARE_VERSION)))
    hits = extract(tmp_path, pklg(noise + acl(att_write(p.encode(p.Cmd.SET_ENCRYPTION_KEY, TOKEN)))))
    assert len(hits) == 1
    assert hits[0].token.raw == TOKEN
    assert hits[0].att_handle == ATT_HANDLE and hits[0].connection == CONN


def test_pklg_fragmented_little_endian(tmp_path):
    packets = acl(att_write(p.encode(p.Cmd.SET_ENCRYPTION_KEY, TOKEN)), fragment=27)
    assert len(packets) > 1
    hits = extract(tmp_path, pklg(packets, big_endian=False))
    assert [h.token.key for h in hits] == [bytes(range(16))]


def test_btsnoop(tmp_path):
    hits = extract(tmp_path, btsnoop(acl(att_write(p.encode(p.Cmd.SET_ENCRYPTION_KEY, TOKEN)))))
    assert hits[0].token.device_id == "0807060504030201"


def test_sysdiagnose_archive(tmp_path):
    import io
    import tarfile

    blob = pklg(acl(att_write(p.encode(p.Cmd.SET_ENCRYPTION_KEY, TOKEN))))
    archive = tmp_path / "sysdiagnose_2026.10.20.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        info = tarfile.TarInfo("sysdiagnose/logs/Bluetooth/bluetoothd-hci-latest.pklg")
        info.size = len(blob)
        tar.addfile(info, io.BytesIO(blob))
    hits = hcilog.find_key_tokens(archive)
    assert [h.token.raw for h in hits] == [TOKEN]


def test_prepared_long_write(tmp_path):
    value = p.encode(p.Cmd.SET_ENCRYPTION_KEY, TOKEN)
    pdus = []
    for offset in range(0, len(value), 18):
        part = value[offset : offset + 18]
        att = bytes([hcilog.ATT_PREPARE_WRITE_REQ]) + struct.pack("<HH", ATT_HANDLE, offset) + part
        pdus += acl(struct.pack("<HH", len(att), hcilog.ATT_CID) + att)
    execute = bytes([hcilog.ATT_EXECUTE_WRITE_REQ, 0x01])
    pdus += acl(struct.pack("<HH", len(execute), hcilog.ATT_CID) + execute)
    hits = extract(tmp_path, pklg(pdus))
    assert hits[0].token.raw == TOKEN
