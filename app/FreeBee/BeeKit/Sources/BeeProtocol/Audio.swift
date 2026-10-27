import CommonCrypto
import Foundation

/// AES-128-CTR as the Bee uses it for audio: each notification is a 4-byte big-endian sequence number
/// followed by ciphertext, and the counter block is `session nonce (12) || sequence number (4)`, so every
/// packet decrypts on its own. There's no authentication tag.
public struct AudioCipher: Sendable {
    public let key: Data
    public let nonce: Data

    public init(key: Data, nonce: Data) throws {
        guard key.count == kCCKeySizeAES128 else { throw ProtocolError.badAudioKey(key.count) }
        guard nonce.count == 12 else { throw ProtocolError.badNonce(nonce) }
        self.key = Data(key)
        self.nonce = Data(nonce)
    }

    /// Splits a notification into its sequence number and plaintext.
    public func decrypt(packet: Data) throws -> (sequence: UInt32, plaintext: Data) {
        guard packet.count >= 4 else { throw ProtocolError.tooShort("audio packet", packet) }
        let bytes = [UInt8](packet.prefix(4))
        let sequence = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return (sequence, try decrypt(packet.dropFirst(4), sequence: sequence))
    }

    public func decrypt(_ ciphertext: Data, sequence: UInt32) throws -> Data {
        let iv = nonce + Data(sequence.bigEndianBytes)
        var cryptor: CCCryptorRef?
        var status = key.withUnsafeBytes { key in
            iv.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    iv.baseAddress, key.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { throw ProtocolError.crypto(status) }
        defer { CCCryptorRelease(cryptor) }
        var out = Data(count: ciphertext.count)
        var moved = 0
        status = ciphertext.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
            }
        }
        guard status == kCCSuccess else { throw ProtocolError.crypto(status) }
        return out.prefix(moved)
    }

    /// Encrypts like the Bee does. CTR is symmetric; the simulator and the tests use this.
    public func encrypt(_ plaintext: Data, sequence: UInt32) throws -> Data {
        Data(sequence.bigEndianBytes) + (try decrypt(plaintext, sequence: sequence))
    }
}

/// An ADTS header (ISO/IEC 13818-7). Our Bee sends AAC-LC, 16 kHz, mono, no CRC.
public struct ADTSHeader: Hashable, Sendable {
    public static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    /// Every AAC frame carries this many samples per channel.
    public static let samplesPerFrame = 1024

    /// 1 = AAC Main, 2 = AAC-LC, 3 = SSR.
    public let audioObjectType: Int
    public let sampleRateIndex: Int
    public let channels: Int
    public let hasCRC: Bool
    /// Header plus payload.
    public let frameLength: Int

    public var headerLength: Int { hasCRC ? 9 : 7 }
    public var sampleRate: Int { ADTSHeader.sampleRates[sampleRateIndex] }
    public var frameDuration: TimeInterval { Double(ADTSHeader.samplesPerFrame) / Double(sampleRate) }

    /// The fields that stay the same for a whole stream: version, layer, CRC flag, profile, sample rate and
    /// channel configuration. A false sync word almost never matches these.
    let fixedBits: UInt32

    /// Parses the 7 bytes at `offset`. Nil unless it's a plausible header.
    public init?(_ bytes: [UInt8], at offset: Int = 0) {
        guard bytes.count - offset >= 7 else { return nil }
        let b1 = bytes[offset + 1], b2 = bytes[offset + 2], b3 = bytes[offset + 3]
        // 12-bit sync word, then layer must be 0.
        guard bytes[offset] == 0xFF, b1 & 0xF6 == 0xF0 else { return nil }
        let index = Int(b2 >> 2) & 0x0F
        let channels = Int(b2 & 0x01) << 2 | Int(b3 >> 6)
        guard index < ADTSHeader.sampleRates.count, channels > 0 else { return nil }
        hasCRC = b1 & 0x01 == 0
        audioObjectType = Int(b2 >> 6) + 1
        sampleRateIndex = index
        self.channels = channels
        frameLength = Int(b3 & 0x03) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5] >> 5)
        fixedBits = UInt32(b1 & 0x0F) << 16 | UInt32(b2 & 0xFD) << 8 | UInt32(b3 & 0xC0)
        guard frameLength > headerLength else { return nil }
    }

    /// A header for a raw AAC payload. Used to wrap encoder output (the simulator).
    public static func header(payloadLength: Int, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let index = sampleRates.firstIndex(of: sampleRate) ?? 8
        let length = payloadLength + 7
        let profile = 1 // AAC-LC (object type 2)
        return Data([
            0xFF, 0xF1,
            UInt8(profile << 6 | index << 2 | channels >> 2),
            UInt8((channels & 3) << 6 | (length >> 11) & 0x03),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x07) << 5 | 0x1F),
            0xFC,
        ])
    }
}

/// Buffers plaintext and yields whole ADTS frames, header included.
///
/// Packets don't line up with frames (about 1.9 frames straddle each 491-byte packet), and a lost packet
/// leaves a torn frame, so this resyncs on the next sync word. Until the stream's fixed header is known it
/// only accepts a frame whose successor starts where its length says; after that, every frame has to
/// match it. The official app drops the first 3 frames of each stream (encoder warm-up); so does this.
public struct ADTSReassembler: Sendable {
    public private(set) var format: ADTSHeader?
    public private(set) var frames = 0
    /// Bytes skipped looking for a sync word.
    public private(set) var resyncBytes = 0
    /// Sync words that turned out not to start a frame.
    public private(set) var falseSyncs = 0
    /// Partial frames thrown away because a packet went missing.
    public private(set) var tornFrames = 0

    private var buffer: [UInt8] = []
    private var skip: Int
    private let skipFrames: Int

    public init(skipFrames: Int = 3) {
        self.skipFrames = skipFrames
        skip = skipFrames
    }

    /// The stream's format is confirmed: frames chain, so the key and nonce are right.
    public var isLocked: Bool { format != nil }

    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var out: [Data] = []
        while let frame = nextFrame() {
            if skip > 0 {
                skip -= 1
            } else {
                out.append(frame)
            }
        }
        // Don't let a stream of garbage (wrong key) grow the buffer.
        if buffer.count > 16_384 {
            resyncBytes += buffer.count - 1
            buffer.removeFirst(buffer.count - 1)
        }
        return out
    }

    /// A packet was lost: whatever is buffered belongs to a frame that can't be completed.
    public mutating func discontinuity() {
        if !buffer.isEmpty { tornFrames += 1 }
        buffer.removeAll(keepingCapacity: true)
    }

    /// A new stream (new nonce, or the sequence restarted): the warm-up frames come again.
    public mutating func restart() {
        buffer.removeAll(keepingCapacity: true)
        skip = skipFrames
    }

    private mutating func nextFrame() -> Data? {
        while true {
            guard let start = syncIndex() else {
                let keep = buffer.last == 0xFF ? 1 : 0 // a sync word may straddle the next packet
                resyncBytes += buffer.count - keep
                buffer.removeFirst(buffer.count - keep)
                return nil
            }
            if start > 0 {
                resyncBytes += start
                buffer.removeFirst(start)
            }
            guard buffer.count >= 7 else { return nil }
            guard let header = ADTSHeader(buffer), format.map({ $0.fixedBits == header.fixedBits }) ?? true else {
                skipFalseSync()
                continue
            }
            if format == nil {
                // Not locked yet: the next frame has to start right after this one.
                guard buffer.count >= header.frameLength + 7 else { return nil }
                guard let next = ADTSHeader(buffer, at: header.frameLength), next.fixedBits == header.fixedBits else {
                    skipFalseSync()
                    continue
                }
                format = header
            }
            guard buffer.count >= header.frameLength else { return nil }
            let frame = Data(buffer[..<header.frameLength])
            buffer.removeFirst(header.frameLength)
            frames += 1
            return frame
        }
    }

    private mutating func skipFalseSync() {
        falseSyncs += 1
        resyncBytes += 1
        buffer.removeFirst()
    }

    private func syncIndex() -> Int? {
        guard buffer.count >= 2 else { return nil }
        for i in 0..<(buffer.count - 1) where buffer[i] == 0xFF && buffer[i + 1] & 0xF6 == 0xF0 {
            return i
        }
        return nil
    }
}

/// One connection's audio: decrypts notifications, tracks sequence numbers and reassembles frames.
public struct AudioStream: Sendable {
    public struct Stats: Hashable, Sendable, Codable {
        public var packets = 0
        public var bytes = 0
        public var frames = 0
        /// Sequence numbers that never arrived.
        public var lostPackets = 0
        public var duplicatePackets = 0
        /// The sequence number went backwards: the Bee restarted the stream.
        public var restarts = 0
        public var resyncBytes = 0
        public var falseSyncs = 0
        public var tornFrames = 0
        public var minPacket = 0
        public var maxPacket = 0

        public init() {}

        public var lossRate: Double {
            let expected = packets + lostPackets
            return expected == 0 ? 0 : Double(lostPackets) / Double(expected)
        }
    }

    public let cipher: AudioCipher
    public private(set) var stats = Stats()
    public private(set) var lastSequence: UInt32?
    /// The first packet of a fresh stream (sequence 0) decrypted to an ADTS sync word: key and nonce are right.
    public private(set) var firstPacketHadSync: Bool?
    private var reassembler: ADTSReassembler

    public init(key: Data, nonce: Data, skipFrames: Int = 3) throws {
        cipher = try AudioCipher(key: key, nonce: nonce)
        reassembler = ADTSReassembler(skipFrames: skipFrames)
    }

    /// Frames chain with a consistent header. With the wrong key this never happens.
    public var isVerified: Bool { reassembler.isLocked }
    public var format: ADTSHeader? { reassembler.format }

    /// Returns the complete ADTS frames this notification finished.
    public mutating func receive(_ packet: Data) throws -> [Data] {
        let (sequence, plaintext) = try cipher.decrypt(packet: packet)
        stats.packets += 1
        stats.bytes += packet.count
        stats.minPacket = stats.minPacket == 0 ? packet.count : min(stats.minPacket, packet.count)
        stats.maxPacket = max(stats.maxPacket, packet.count)
        if let last = lastSequence {
            if sequence == last {
                stats.duplicatePackets += 1
                return []
            } else if sequence < last {
                stats.restarts += 1
                reassembler.restart()
            } else if sequence > last + 1 {
                stats.lostPackets += Int(sequence - last - 1)
                reassembler.discontinuity()
            }
        }
        if sequence == 0 { firstPacketHadSync = plaintext.count >= 2 && plaintext[plaintext.startIndex] == 0xFF && plaintext[plaintext.startIndex + 1] & 0xF0 == 0xF0 }
        lastSequence = sequence
        let frames = reassembler.feed(plaintext)
        stats.frames += frames.count
        stats.resyncBytes = reassembler.resyncBytes
        stats.falseSyncs = reassembler.falseSyncs
        stats.tornFrames = reassembler.tornFrames
        return frames
    }
}

/// Reads back an archived ADTS file: how many frames it holds and in what format. Used to recover a
/// segment whose index wasn't updated before the app was killed.
public enum ADTSFile {
    public static func scan(_ data: Data) -> (frames: Int, format: ADTSHeader?) {
        let bytes = [UInt8](data)
        let frames = frames(in: bytes)
        return (frames.count, frames.isEmpty ? nil : ADTSHeader(bytes))
    }

    /// Where each whole frame sits in the file, in order, up to the first thing that isn't one.
    public static func frames(in data: Data) -> [Range<Int>] {
        frames(in: [UInt8](data))
    }

    private static func frames(in bytes: [UInt8]) -> [Range<Int>] {
        var offset = 0
        var frames: [Range<Int>] = []
        while offset + 7 <= bytes.count {
            guard let header = ADTSHeader(bytes, at: offset), offset + header.frameLength <= bytes.count else { break }
            frames.append(offset..<offset + header.frameLength)
            offset += header.frameLength
        }
        return frames
    }
}
