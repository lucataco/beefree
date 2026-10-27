import Foundation

extension Data {
    /// Parses hex text. Whitespace, `:` separators and a leading `0x` are ignored.
    public init?(hex: String) {
        var text = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("0x") || text.hasPrefix("0X") { text = text.dropFirst(2) }
        let digits = text.filter { !$0.isWhitespace && $0 != ":" }
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var iterator = digits.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = high.hexDigitValue, let l = low.hexDigitValue else { return nil }
            bytes.append(UInt8(h << 4 | l))
        }
        self.init(bytes)
    }

    /// Lowercase hex, two digits per byte.
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    func le16(at i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func be16(at i: Int) -> UInt16 { UInt16(self[i]) << 8 | UInt16(self[i + 1]) }
    func le32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

extension FixedWidthInteger {
    /// Little-endian bytes of this integer.
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian, Array.init) }
}
