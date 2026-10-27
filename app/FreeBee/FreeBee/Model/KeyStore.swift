import BeeProtocol
import Foundation
import Security

/// Pairing tokens in the Keychain, one per Bee device id. Readable after first unlock so a background
/// reconnect can open a session, and never synced off this iPhone.
enum KeyStore {
    private static let service = "bee.pairing-token"

    struct KeychainError: LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    static func save(_ token: SealedToken) throws {
        delete(deviceID: token.deviceID)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: token.deviceID,
            kSecAttrLabel as String: "Bee pairing token",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: token.raw,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func token(for deviceID: String) -> SealedToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? SealedToken(raw: data)
    }

    static func all() -> [SealedToken] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [Data] else { return [] }
        return items.compactMap { try? SealedToken(raw: $0) }.sorted { $0.deviceID < $1.deviceID }
    }

    static func delete(deviceID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
