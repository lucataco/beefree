import Foundation

/// Read-only MCUmgr/SMP framing: firmware image slots, bootloader and buffer parameters.
///
/// There's deliberately no way to build a write here. Nothing in this file can upload, erase,
/// test, confirm or reset firmware images.
public enum SMP {
    public static let headerLength = 8

    public enum Op {
        public static let read: UInt8 = 0
        public static let readResponse: UInt8 = 1
    }

    public enum Group {
        public static let os: UInt16 = 0
        public static let image: UInt16 = 1
    }

    public enum OSCommand {
        public static let mcumgrParams: UInt8 = 6
        public static let appInfo: UInt8 = 7
        public static let bootloaderInfo: UInt8 = 8
    }

    public enum ImageCommand {
        public static let state: UInt8 = 0
    }

    /// `op, flags, len (BE16), group (BE16), seq, id`
    public struct Header: Hashable, Sendable {
        public var op: UInt8
        public var flags: UInt8
        public var length: UInt16
        public var group: UInt16
        public var sequence: UInt8
        public var command: UInt8

        public init(op: UInt8, flags: UInt8 = 0, length: UInt16, group: UInt16, sequence: UInt8, command: UInt8) {
            self.op = op
            self.flags = flags
            self.length = length
            self.group = group
            self.sequence = sequence
            self.command = command
        }

        init(_ b: [UInt8]) {
            self.init(op: b[0], flags: b[1], length: b.be16(at: 2), group: b.be16(at: 4), sequence: b[6], command: b[7])
        }

        public var bytes: Data {
            Data([op, flags] + length.bigEndianBytes + group.bigEndianBytes + [sequence, command])
        }
    }

    public struct Frame: Hashable, Sendable {
        public var header: Header
        public var body: Data

        public func decodedBody() throws -> CBOR {
            body.isEmpty ? .map([]) : try CBORDecoder.decode(body)
        }
    }

    /// A read request (op 0) with a CBOR body.
    public static func readRequest(group: UInt16, command: UInt8, sequence: UInt8, body: CBOR = [:]) -> Data {
        let payload = CBOREncoder.encode(body)
        let header = Header(op: Op.read, length: UInt16(payload.count), group: group, sequence: sequence, command: command)
        return header.bytes + payload
    }

    /// Joins notifications back into frames: a reply can span several, and the header carries the body length.
    public struct Reassembler: Sendable {
        private var buffer: [UInt8] = []

        public init() {}

        public mutating func append(_ data: Data) -> [Frame] {
            buffer += data
            var frames: [Frame] = []
            while buffer.count >= SMP.headerLength {
                let header = Header(Array(buffer.prefix(SMP.headerLength)))
                let total = SMP.headerLength + Int(header.length)
                guard buffer.count >= total else { break }
                frames.append(Frame(header: header, body: Data(buffer[SMP.headerLength..<total])))
                buffer.removeFirst(total)
            }
            return frames
        }

        public mutating func reset() { buffer.removeAll() }
    }

    public static let returnCodeNames: [Int: String] = [
        1: "EUNKNOWN", 2: "ENOMEM", 3: "EINVAL", 4: "ETIMEOUT", 5: "ENOENT", 6: "EBADSTATE",
        7: "EMSGSIZE", 8: "ENOTSUP", 9: "ECORRUPT", 10: "EBUSY", 11: "EACCESSDENIED",
    ]

    public struct ResponseError: Error, Hashable, Sendable, CustomStringConvertible {
        public var rc: Int
        public var group: Int?

        public init(rc: Int, group: Int? = nil) {
            self.rc = rc
            self.group = group
        }

        public var name: String { SMP.returnCodeNames[rc] ?? "?" }
        public var isNotSupported: Bool { rc == 8 }
        public var description: String { "SMP rc=\(rc) (\(name))" }
    }

    /// Throws for SMP v1 `{"rc": n}` and v2 `{"err": {"group": g, "rc": n}}` errors.
    public static func check(_ body: CBOR) throws {
        if let rc = body["rc"]?.int, rc != 0 { throw ResponseError(rc: rc) }
        if let err = body["err"], let rc = err["rc"]?.int, rc != 0 { throw ResponseError(rc: rc, group: err["group"]?.int) }
    }
}

/// One firmware image slot from the image-state query.
public struct ImageSlot: Hashable, Sendable, Identifiable {
    public var image: Int
    public var slot: Int
    public var version: String
    public var hash: Data?
    public var active: Bool
    public var confirmed: Bool
    public var pending: Bool
    public var permanent: Bool
    public var bootable: Bool

    public var id: String { "\(image)-\(slot)" }
    public var firmwareVersion: FirmwareVersion? { FirmwareVersion(version) }

    /// Flag names in the order `beekit fw` prints them.
    public var flags: [String] {
        [("active", active), ("confirmed", confirmed), ("pending", pending), ("permanent", permanent), ("bootable", bootable)]
            .filter(\.1).map(\.0)
    }

    public static func parseImageState(_ body: CBOR) -> [ImageSlot] {
        (body["images"]?.array ?? []).map { image in
            ImageSlot(
                image: image["image"]?.int ?? 0,
                slot: image["slot"]?.int ?? 0,
                version: image["version"]?.string ?? "?",
                hash: image["hash"]?.data,
                active: image["active"]?.bool ?? false,
                confirmed: image["confirmed"]?.bool ?? false,
                pending: image["pending"]?.bool ?? false,
                permanent: image["permanent"]?.bool ?? false,
                bootable: image["bootable"]?.bool ?? false
            )
        }
    }
}

/// MCUmgr buffer parameters.
public struct SMPParameters: Hashable, Sendable {
    public var bufferSize: Int?
    public var bufferCount: Int?

    public init(_ body: CBOR) {
        bufferSize = body["buf_size"]?.int
        bufferCount = body["buf_count"]?.int
    }
}
