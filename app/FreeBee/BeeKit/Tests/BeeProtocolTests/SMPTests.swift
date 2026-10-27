import BeeProtocol
import Foundation
import Testing

// Vectors encoded by Python's cbor2 (the library beekit uses), shaped like our Bee's replies:
// slot 0 = 0.6.1 (active, confirmed), slot 1 = 0.5.0 (bootable).
let imageStateBody = hex(
    "a266696d6167657382a864736c6f74006776657273696f6e65302e362e3164686173685820000102030405060708090a0b0c0d0e0f"
        + "101112131415161718191a1b1c1d1e1f68626f6f7461626c65f56770656e64696e67f469636f6e6669726d6564f566616374697665"
        + "f5697065726d616e656e74f4a864736c6f74016776657273696f6e65302e352e3064686173685820202122232425262728292a2b2c"
        + "2d2e2f303132333435363738393a3b3c3d3e3f68626f6f7461626c65f56770656e64696e67f469636f6e6669726d6564f466616374"
        + "697665f4697065726d616e656e74f46b73706c697453746174757300"
)

@Test func decodesImageState() throws {
    let slots = ImageSlot.parseImageState(try CBORDecoder.decode(imageStateBody))
    #expect(slots.count == 2)
    #expect(slots[0].version == "0.6.1")
    #expect(slots[0].flags == ["active", "confirmed", "bootable"])
    #expect(slots[0].hash == Data(0..<32))
    #expect(slots[1].version == "0.5.0")
    #expect(slots[1].flags == ["bootable"])
    #expect(slots[1].firmwareVersion == FirmwareVersion(major: 0, minor: 5, patch: 0))
}

@Test func decodesOtherReplies() throws {
    #expect(try CBORDecoder.decode(hex("a16a626f6f746c6f61646572674d4355626f6f74"))["bootloader"]?.string == "MCUboot")
    let params = SMPParameters(try CBORDecoder.decode(hex("a2686275665f73697a651909ab696275665f636f756e7404")))
    #expect(params == SMPParameters(["buf_size": 2475, "buf_count": 4]))
    #expect(params.bufferSize == 2475)
    #expect(params.bufferCount == 4)
}

@Test func returnCodesBecomeErrors() throws {
    #expect(throws: SMP.ResponseError(rc: 8)) { try SMP.check(CBORDecoder.decode(hex("a162726308"))) }
    #expect(throws: SMP.ResponseError(rc: 8, group: 0)) { try SMP.check(CBORDecoder.decode(hex("a163657272a26567726f75700062726308"))) }
    try SMP.check(["rc": 0])
    #expect(SMP.ResponseError(rc: 8).isNotSupported)
}

@Test func cborScalars() throws {
    let misc = try CBORDecoder.decode(hex("87203901f3fb3ff8000000000000f640601b0000010000000000"))
    #expect(misc == [-1, -500, 1.5, nil, .bytes(Data()), "", .unsigned(1 << 40)])
    #expect(misc.array?[1].int == -500)
    #expect(try CBORDecoder.decode(hex("f93e00")) == .float(1.5))  // half precision
    #expect(try CBORDecoder.decode(hex("f90001")) == .float(0x1p-24))  // smallest subnormal half
    #expect(try CBORDecoder.decode(hex("c11a514b67b0")) == .tagged(1, .unsigned(1_363_896_240)))
}

@Test func cborIndefiniteLengths() throws {
    // {_ "images": [_ {_ "slot": 0, "version": (_ "0.6", ".1")}]}  (tinycbor-era MCUmgr style)
    let body = hex("bf66696d616765739fbf64736c6f74006776657273696f6e7f63302e36622e31ffffffff")
    let slots = ImageSlot.parseImageState(try CBORDecoder.decode(body))
    #expect(slots.map(\.version) == ["0.6.1"])
    #expect(try CBORDecoder.decode(hex("5f42010241ffff")) == .bytes(Data([1, 2, 0xFF])))
}

@Test func cborRejectsBadInput() {
    #expect(throws: CBORError.truncated) { try CBORDecoder.decode(hex("a2")) }
    #expect(throws: CBORError.truncated) { try CBORDecoder.decode(hex("5affffffff00")) }
    #expect(throws: CBORError.trailingBytes(1)) { try CBORDecoder.decode(hex("0000")) }
    #expect(throws: CBORError.self) { try CBORDecoder.decode(hex("ff")) }
    #expect(throws: CBORError.self) { try CBORDecoder.decode(hex("62c328")) }  // invalid UTF-8
    #expect(throws: CBORError.self) { try CBORDecoder.decode(Data(repeating: 0x81, count: 100) + Data([0])) }
}

@Test func cborRoundTrip() throws {
    #expect(CBOREncoder.encode(["format": "a"]) == hex("a166666f726d61746161"))
    #expect(CBOREncoder.encode([:]) == hex("a0"))
    #expect(CBOREncoder.encode(["buf_size": 2475, "buf_count": 4]) == hex("a2686275665f73697a651909ab696275665f636f756e7404"))
    let decoded = try CBORDecoder.decode(imageStateBody)
    #expect(CBOREncoder.encode(decoded) == imageStateBody)
    let value: CBOR = [1, -1, 255, 256, 65536, .unsigned(UInt64.max), true, false, nil, 2.5, .bytes(Data([9])), ["k": "v"]]
    #expect(try CBORDecoder.decode(CBOREncoder.encode(value)) == value)
}

@Test func readRequestIsOpZero() {
    let request = SMP.readRequest(group: SMP.Group.os, command: SMP.OSCommand.appInfo, sequence: 3, body: ["format": "a"])
    // op 0, flags 0, len 10, group 0, seq 3, id 7
    #expect(request == hex("0000000a00000307") + hex("a166666f726d61746161"))
}

@Test func reassemblesSplitReplies() throws {
    let frame = hex("010000f000010700") + imageStateBody
    var reassembler = SMP.Reassembler()
    var frames: [SMP.Frame] = []
    for start in stride(from: 0, to: frame.count, by: 20) {
        frames += reassembler.append(frame.subdata(in: start..<min(start + 20, frame.count)))
    }
    #expect(frames.count == 1)
    #expect(frames[0].header == SMP.Header(op: SMP.Op.readResponse, length: 0xF0, group: SMP.Group.image, sequence: 7, command: 0))
    #expect(frames[0].body == imageStateBody)

    // Two frames in one notification.
    let small = hex("0100000500000808") + hex("a16272630a")
    let both = reassembler.append(small + small)
    #expect(both.count == 2)
    #expect(throws: SMP.ResponseError(rc: 10)) { try SMP.check(both[0].decodedBody()) }
}
