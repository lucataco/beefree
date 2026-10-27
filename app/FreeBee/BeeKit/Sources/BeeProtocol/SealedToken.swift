import CryptoKit
import Foundation

/// The SetEncryptionKey payload the official app sends at pairing.
///
/// Layout: `"SKV1"` magic (4) | device id (8) | AES-128-CTR audio key (16) | sealed trailer (80).
/// The first SetEncryptionKey of a connection must be the device's current real token.
public struct SealedToken: Hashable, Sendable {
    public static let magic = Data("SKV1".utf8)
    public static let expectedLength = 108

    public let raw: Data

    public init(raw: Data) throws {
        guard raw.count >= 28, raw.prefix(4) == SealedToken.magic else { throw ProtocolError.notAToken }
        self.raw = Data(raw)
    }

    public var deviceID: String { (try? DeviceID.format(raw.subdata(in: 4..<12))) ?? "" }
    public var key: Data { raw.subdata(in: 12..<28) }
    public var hasExpectedLength: Bool { raw.count == SealedToken.expectedLength }

    /// First 12 hex digits of SHA-256(key), the same `key#...` beekit prints, so the two can be compared.
    public var fingerprint: String { String(Data(SHA256.hash(data: key)).hex.prefix(12)) }
}

/// Reads beekit's `~/.config/beekit/secrets.json`, or a bare token in hex.
///
/// ```json
/// {"devices": {"<device id>": {"token_hex": "534b5631...", "source": "...", "saved_at": "..."}}}
/// ```
public enum KeyFile {
    public struct Entry: Hashable, Sendable {
        public var token: SealedToken
        public var source: String?
        public var savedAt: String?

        public var deviceID: String { token.deviceID }
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return try parse(json: object)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ProtocolError.unreadableKeyFile("not text") }
        return [Entry(token: try parseHex(text), source: nil, savedAt: nil)]
    }

    /// A token pasted as hex (spaces and colons allowed).
    public static func parseHex(_ text: String) throws -> SealedToken {
        guard let raw = Data(hex: text) else { throw ProtocolError.unreadableKeyFile("not hex") }
        return try SealedToken(raw: raw)
    }

    private static func parse(json object: Any) throws -> [Entry] {
        guard let root = object as? [String: Any] else { throw ProtocolError.unreadableKeyFile("expected a JSON object") }
        guard let devices = root["devices"] as? [String: Any] else {
            throw ProtocolError.unreadableKeyFile("no \"devices\" in the file")
        }
        let entries = try devices.sorted { $0.key < $1.key }.map { _, value -> Entry in
            guard let device = value as? [String: Any], let hex = device["token_hex"] as? String else {
                throw ProtocolError.unreadableKeyFile("a device has no token_hex")
            }
            return Entry(token: try parseHex(hex), source: device["source"] as? String, savedAt: device["saved_at"] as? String)
        }
        guard !entries.isEmpty else { throw ProtocolError.unreadableKeyFile("the file lists no devices") }
        return entries
    }
}
