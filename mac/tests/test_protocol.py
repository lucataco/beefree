from beekit import protocol as p

# Response framing captured from our unit (firmware 0.6.1); device-id bytes replaced with a dummy.
DUMMY_ID = bytes.fromhex("0102030405060708")


def test_encode_is_little_endian_command_id():
    assert p.encode(p.Cmd.GET_FIRMWARE_VERSION) == b"\x05\xc0"
    assert p.encode(p.Cmd.SET_BRIGHTNESS, b"\x01\x32") == b"\x16\xc0\x01\x32"


def test_decode_firmware_response():
    msg = p.decode(bytes.fromhex("008005c0010600"))
    assert msg.ok and msg.command == p.Cmd.GET_FIRMWARE_VERSION
    assert str(p.FirmwareVersion.parse(msg.payload)) == "0.6.1"


def test_decode_battery_and_state():
    battery = p.Battery.parse(p.decode(bytes.fromhex("00800fc06401")).payload)
    assert battery == p.Battery(100, True)
    assert p.parse_device_state(p.decode(bytes.fromhex("00800ac00101")).payload) == (
        p.DeviceState.RECORDING,
        p.Codec.AAC,
    )


def test_error_responses_echo_the_command():
    msg = p.decode(bytes.fromhex("03801dc0"))
    assert not msg.ok
    assert msg.name == "UNKNOWN_MESSAGE"
    assert msg.command == p.Cmd.GET_DSN


def test_device_id_matches_between_response_and_advert():
    msg = p.decode(bytes.fromhex("00800ec0") + DUMMY_ID)
    assert p.format_device_id(msg.payload) == "0807060504030201"
    advert = p.Advertisement.parse({p.LEGACY_COMPANY_ID: DUMMY_ID})
    assert advert == p.Advertisement("0807060504030201", "legacy")
    assert p.parse_secure_ids(DUMMY_ID + b"\x00") == ("0807060504030201", False)


def test_frontier_advert():
    advert = p.Advertisement.parse({p.FRONTIER_COMPANY_ID: DUMMY_ID + bytes([1, 4, 1])})
    assert advert == p.Advertisement("0807060504030201", "frontier", 4, True)


def test_events():
    assert p.decode(bytes.fromhex("03a00101")).is_event
    assert p.describe_event(p.decode(bytes.fromhex("03a00101"))) == "state: recording (codec aac)"
    assert p.describe_event(p.decode(bytes.fromhex("04a064"))) == "battery: 100%"
    assert p.describe_event(p.decode(bytes.fromhex("05a001"))) == "charging: yes"
    assert p.describe_event(p.decode(bytes.fromhex("02a001"))) == "button: hold"


def test_sealed_token_layout():
    key = bytes(range(16))
    token = p.SealedToken.parse(b"SKV1" + DUMMY_ID + key + bytes(80))
    assert token.device_id == "0807060504030201"
    assert token.key == key
