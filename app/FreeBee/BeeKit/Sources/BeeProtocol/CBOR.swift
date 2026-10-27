import Foundation

/// A minimal CBOR (RFC 8949) value: enough to read MCUmgr/SMP replies and write their small request bodies.
public indirect enum CBOR: Hashable, Sendable {
    case unsigned(UInt64)
    /// Encodes the integer `-1 - n`.
    case negative(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    /// Pairs in wire order.
    case map([Pair])
    case tagged(UInt64, CBOR)
    case bool(Bool)
    case null
    case undefined
    case float(Double)
    case simple(UInt8)

    public struct Pair: Hashable, Sendable {
        public var key: CBOR
        public var value: CBOR

        public init(_ key: CBOR, _ value: CBOR) {
            self.key = key
            self.value = value
        }
    }

    public static func int(_ value: Int) -> CBOR {
        value >= 0 ? .unsigned(UInt64(value)) : .negative(UInt64(-1 - value))
    }

    public subscript(key: String) -> CBOR? {
        guard case let .map(pairs) = self else { return nil }
        return pairs.first { $0.key == .text(key) }?.value
    }

    public var int: Int? {
        switch self {
        case let .unsigned(n): Int(exactly: n)
        case let .negative(n): Int(exactly: n).map { -1 - $0 }
        default: nil
        }
    }

    public var string: String? { if case let .text(s) = self { s } else { nil } }
    public var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var data: Data? { if case let .bytes(d) = self { d } else { nil } }
    public var array: [CBOR]? { if case let .array(a) = self { a } else { nil } }
    public var pairs: [Pair]? { if case let .map(p) = self { p } else { nil } }
}

extension CBOR: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: CBOR...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (CBOR, CBOR)...) { self = .map(elements.map { Pair($0, $1) }) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(nilLiteral: ()) { self = .null }
}

public enum CBORError: Error, Hashable, CustomStringConvertible {
    case truncated
    case invalid(String)
    case trailingBytes(Int)

    public var description: String {
        switch self {
        case .truncated: "CBOR ended early"
        case let .invalid(reason): "invalid CBOR: \(reason)"
        case let .trailingBytes(n): "\(n) bytes after the CBOR item"
        }
    }
}

public struct CBORDecoder {
    private let bytes: [UInt8]
    private var index = 0
    private static let maxDepth = 32

    /// Decodes exactly one item; anything after it is an error.
    public static func decode(_ data: Data) throws -> CBOR {
        var decoder = CBORDecoder(bytes: [UInt8](data))
        let value = try decoder.item(depth: 0)
        guard decoder.index == decoder.bytes.count else { throw CBORError.trailingBytes(decoder.bytes.count - decoder.index) }
        return value
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private var remaining: Int { bytes.count - index }

    private mutating func byte() throws -> UInt8 {
        guard index < bytes.count else { throw CBORError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= remaining else { throw CBORError.truncated }
        defer { index += count }
        return bytes[index..<index + count]
    }

    private mutating func uint(_ width: Int) throws -> UInt64 {
        try take(width).reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func argument(_ info: UInt8) throws -> UInt64 {
        switch info {
        case 0..<24: UInt64(info)
        case 24: try uint(1)
        case 25: try uint(2)
        case 26: try uint(4)
        case 27: try uint(8)
        default: throw CBORError.invalid("additional info \(info)")
        }
    }

    private mutating func length(_ info: UInt8) throws -> Int {
        let n = try argument(info)
        // Every element takes at least a byte, so a length past the end of the input is bogus.
        guard n <= UInt64(remaining) else { throw CBORError.truncated }
        return Int(n)
    }

    private mutating func atBreak() throws -> Bool {
        guard index < bytes.count else { throw CBORError.truncated }
        if bytes[index] == 0xFF {
            index += 1
            return true
        }
        return false
    }

    /// IEEE 754 half precision (Float16 isn't available on every platform we build for).
    static func half(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int(bits >> 10 & 0x1F)
        let mantissa = Double(bits & 0x3FF)
        switch exponent {
        case 0: return sign * mantissa * 0x1p-24
        case 31: return mantissa == 0 ? sign * .infinity : .nan
        default: return sign * (1 + mantissa / 1024) * Double(sign: .plus, exponent: exponent - 15, significand: 1)
        }
    }

    private mutating func item(depth: Int) throws -> CBOR {
        guard depth < CBORDecoder.maxDepth else { throw CBORError.invalid("nested too deeply") }
        let initial = try byte()
        let major = initial >> 5
        let info = initial & 0x1F
        switch major {
        case 0:
            return .unsigned(try argument(info))
        case 1:
            return .negative(try argument(info))
        case 2, 3:
            var chunk: [UInt8]
            if info == 31 {
                chunk = []
                while try !atBreak() {
                    switch (major, try item(depth: depth + 1)) {
                    case let (2, .bytes(piece)): chunk += piece
                    case let (3, .text(piece)): chunk += piece.utf8
                    default: throw CBORError.invalid("mixed chunk types in an indefinite string")
                    }
                }
            } else {
                chunk = Array(try take(try length(info)))
            }
            if major == 2 { return .bytes(Data(chunk)) }
            guard let text = String(validating: chunk, as: UTF8.self) else { throw CBORError.invalid("text is not UTF-8") }
            return .text(text)
        case 4:
            var items: [CBOR] = []
            if info == 31 {
                while try !atBreak() { items.append(try item(depth: depth + 1)) }
            } else {
                for _ in 0..<(try length(info)) { items.append(try item(depth: depth + 1)) }
            }
            return .array(items)
        case 5:
            var pairs: [CBOR.Pair] = []
            if info == 31 {
                while try !atBreak() { pairs.append(CBOR.Pair(try item(depth: depth + 1), try item(depth: depth + 1))) }
            } else {
                for _ in 0..<(try length(info)) { pairs.append(CBOR.Pair(try item(depth: depth + 1), try item(depth: depth + 1))) }
            }
            return .map(pairs)
        case 6:
            let tag = try argument(info)
            return .tagged(tag, try item(depth: depth + 1))
        default:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            case 24: return .simple(try byte())
            case 25: return .float(CBORDecoder.half(UInt16(try uint(2))))
            case 26: return .float(Double(Float(bitPattern: UInt32(try uint(4)))))
            case 27: return .float(Double(bitPattern: try uint(8)))
            case 31: throw CBORError.invalid("unexpected break")
            case 0..<20: return .simple(info)
            default: throw CBORError.invalid("simple value \(info)")
            }
        }
    }
}

public enum CBOREncoder {
    public static func encode(_ value: CBOR) -> Data {
        var out = [UInt8]()
        write(value, into: &out)
        return Data(out)
    }

    private static func head(_ major: UInt8, _ n: UInt64, into out: inout [UInt8]) {
        let m = major << 5
        switch n {
        case 0..<24: out.append(m | UInt8(n))
        case 24...0xFF: out += [m | 24, UInt8(n)]
        case 0x100...0xFFFF: out += [m | 25] + UInt16(n).bigEndianBytes
        case 0x10000...0xFFFF_FFFF: out += [m | 26] + UInt32(n).bigEndianBytes
        default: out += [m | 27] + n.bigEndianBytes
        }
    }

    private static func write(_ value: CBOR, into out: inout [UInt8]) {
        switch value {
        case let .unsigned(n): head(0, n, into: &out)
        case let .negative(n): head(1, n, into: &out)
        case let .bytes(d):
            head(2, UInt64(d.count), into: &out)
            out += d
        case let .text(s):
            head(3, UInt64(s.utf8.count), into: &out)
            out += s.utf8
        case let .array(items):
            head(4, UInt64(items.count), into: &out)
            for item in items { write(item, into: &out) }
        case let .map(pairs):
            head(5, UInt64(pairs.count), into: &out)
            for pair in pairs {
                write(pair.key, into: &out)
                write(pair.value, into: &out)
            }
        case let .tagged(tag, item):
            head(6, tag, into: &out)
            write(item, into: &out)
        case let .bool(b): out.append(b ? 0xF5 : 0xF4)
        case .null: out.append(0xF6)
        case .undefined: out.append(0xF7)
        case let .float(d): out += [0xFB] + d.bitPattern.bigEndianBytes
        case let .simple(v): v < 24 ? out.append(0xE0 | v) : (out += [0xF8, v])
        }
    }
}
