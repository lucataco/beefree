import Foundation
import Testing
@testable import BeeProtocol

/// Builds ADTS frames with random payloads of the sizes the Bee sends (213-345 bytes).
func syntheticFrames(_ count: Int, seed: UInt64 = 1) -> [Data] {
    var rng = SplitMix(seed: seed)
    return (0..<count).map { _ in
        let payload = Data((0..<Int(rng.next() % 133 + 206)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        return ADTSHeader.header(payloadLength: payload.count) + payload
    }
}

/// Cuts a plaintext stream into notifications the way the Bee does: 491 bytes of ciphertext per packet.
func packets(for stream: Data, cipher: AudioCipher, size: Int = 491) throws -> [Data] {
    var out: [Data] = []
    var offset = 0
    var sequence: UInt32 = 0
    while offset < stream.count {
        let chunk = stream.subdata(in: offset..<min(offset + size, stream.count))
        out.append(try cipher.encrypt(chunk, sequence: sequence))
        offset += size
        sequence += 1
    }
    return out
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let testKey = Data(hex: "000102030405060708090a0b0c0d0e0f")!
let testNonce = Data(hex: "a0a1a2a3a4a5a6a7a8a9aaab")!

@Test func ctrMatchesNIST() throws {
    // SP 800-38A F.5.2 (CTR-AES128.Decrypt). The counter block f0..fcfdfeff is nonce || sequence, and the
    // second block checks that the counter carries across the sequence number into the nonce.
    let cipher = try AudioCipher(key: Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!, nonce: Data(hex: "f0f1f2f3f4f5f6f7f8f9fafb")!)
    let ciphertext = Data(hex: "874d6191b620e3261bef6864990db6ce 9806f66b7970fdff8617187bb9fffdff")!
    let plaintext = try cipher.decrypt(ciphertext, sequence: 0xFCFD_FEFF)
    #expect(plaintext == Data(hex: "6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51")!)
}

@Test func parsesTheBeesHeader() throws {
    let frame = ADTSHeader.header(payloadLength: 300) + Data(count: 300)
    let header = try #require(ADTSHeader([UInt8](frame)))
    #expect(header.audioObjectType == 2)
    #expect(header.sampleRate == 16000)
    #expect(header.channels == 1)
    #expect(!header.hasCRC)
    #expect(header.frameLength == 307)
    #expect(abs(header.frameDuration - 0.064) < 1e-9)
    #expect(frame.prefix(2) == Data([0xFF, 0xF1]))
}

@Test func reassemblesAcrossPackets() throws {
    let frames = syntheticFrames(120)
    let cipher = try AudioCipher(key: testKey, nonce: testNonce)
    var stream = try AudioStream(key: testKey, nonce: testNonce)
    var out: [Data] = []
    for packet in try packets(for: frames.reduce(Data(), +), cipher: cipher) {
        #expect(packet.count <= 495)
        out += try stream.receive(packet)
    }
    // The first 3 are warm-up; the last one completes only when the next frame's header confirms it, but
    // a locked stream emits it as soon as it's whole.
    #expect(out == Array(frames.dropFirst(3)))
    #expect(stream.isVerified)
    #expect(stream.firstPacketHadSync == true)
    #expect(stream.stats.lostPackets == 0)
    #expect(stream.stats.resyncBytes == 0)
    #expect(stream.stats.frames == 117)
}

@Test func resyncsAfterALostPacket() throws {
    let frames = syntheticFrames(120, seed: 7)
    let cipher = try AudioCipher(key: testKey, nonce: testNonce)
    var all = try packets(for: frames.reduce(Data(), +), cipher: cipher)
    all.remove(at: 20)
    var stream = try AudioStream(key: testKey, nonce: testNonce)
    var out: [Data] = []
    for packet in all { out += try stream.receive(packet) }
    #expect(stream.stats.lostPackets == 1)
    #expect(stream.stats.tornFrames == 1)
    // A lost packet costs the 1-3 frames it touched, never a corrupt one.
    #expect(out.count >= 117 - 3 && out.count < 117)
    #expect(out.allSatisfy { frames.contains($0) })
}

@Test func wrongKeyNeverVerifies() throws {
    let frames = syntheticFrames(60, seed: 3)
    let cipher = try AudioCipher(key: testKey, nonce: testNonce)
    var stream = try AudioStream(key: Data(repeating: 0x55, count: 16), nonce: testNonce)
    var out: [Data] = []
    for packet in try packets(for: frames.reduce(Data(), +), cipher: cipher) { out += try stream.receive(packet) }
    #expect(out.isEmpty)
    #expect(!stream.isVerified)
    #expect(stream.firstPacketHadSync == false)
}

@Test func duplicatesAndRestarts() throws {
    let frames = syntheticFrames(40, seed: 5)
    let cipher = try AudioCipher(key: testKey, nonce: testNonce)
    let all = try packets(for: frames.reduce(Data(), +), cipher: cipher)
    var stream = try AudioStream(key: testKey, nonce: testNonce)
    _ = try stream.receive(all[0])
    _ = try stream.receive(all[0])
    #expect(stream.stats.duplicatePackets == 1)
    for packet in all.dropFirst() { _ = try stream.receive(packet) }
    // The stream starts over at sequence 0.
    var again: [Data] = []
    for packet in all { again += try stream.receive(packet) }
    #expect(stream.stats.restarts == 1)
    #expect(again == Array(frames.dropFirst(3)))
}

@Test func scansAnArchivedFile() {
    let frames = syntheticFrames(25, seed: 9)
    let (count, format) = ADTSFile.scan(frames.reduce(Data(), +) + Data([0xFF, 0xF1, 0x60]))
    #expect(count == 25)
    #expect(format?.sampleRate == 16000)
    let ranges = ADTSFile.frames(in: frames.reduce(Data(), +))
    #expect(ranges.count == 25)
    #expect(ranges.map(\.count) == frames.map(\.count))
    #expect(ranges.last?.upperBound == frames.reduce(0) { $0 + $1.count })
}

// MARK: - the real capture

/// `captures/` at the repository root (`beekit audio --out-dir ../captures` from `mac/`). Git-ignored.
private let captureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("captures")
private let rawCapture = captureDirectory.appendingPathComponent("20261020-201740-raw.jsonl")
private let macDecode = captureDirectory.appendingPathComponent("20261020-201740.aac")
private let secrets = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/beekit/secrets.json")
private let haveCapture = [rawCapture, macDecode, secrets].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }

/// The 45 s capture from the Mac, decoded here, has to match what beekit wrote byte for byte.
/// Only runs where the capture and the key are on disk; neither is in the repo.
@Test(.enabled(if: haveCapture)) func matchesTheMacPipeline() throws {
    let lines = try String(contentsOf: rawCapture, encoding: .utf8).split(separator: "\n")
    let header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    let deviceID = try #require(header["device_id"] as? String)
    let nonceHex = try #require(header["nonce"] as? String)
    let nonce = try #require(Data(hex: nonceHex))
    let entry = try #require(try KeyFile.parse(Data(contentsOf: secrets)).first { $0.deviceID == deviceID })

    var stream = try AudioStream(key: entry.token.key, nonce: nonce)
    var decoded = Data()
    for line in lines.dropFirst() {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let hex = try #require(object["hex"] as? String)
        let packet = try #require(Data(hex: hex))
        for frame in try stream.receive(packet) { decoded += frame }
    }
    #expect(stream.stats.packets == 366)
    #expect(stream.stats.frames == 698)
    #expect(stream.stats.lostPackets == 0)
    #expect(stream.isVerified)
    #expect(stream.firstPacketHadSync == true)
    #expect(decoded == (try Data(contentsOf: macDecode)))
}
