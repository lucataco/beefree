import Foundation

/// What the widget shows. The app writes it to the shared App Group defaults; the widget only reads it.
nonisolated struct BeeSnapshot: Codable, Hashable, Sendable {
    enum Activity: String, Codable, Sendable {
        case listening, muted, sleeping, off, unknown

        var label: String {
            switch self {
            case .listening: "Listening"
            case .muted: "Muted"
            case .sleeping: "Asleep"
            case .off: "Off"
            case .unknown: "Unknown"
            }
        }

        var symbol: String {
            switch self {
            case .listening: "waveform"
            case .muted: "mic.slash.fill"
            case .sleeping: "moon.zzz.fill"
            case .off: "power"
            case .unknown: "questionmark"
            }
        }
    }

    var name: String
    var battery: Int?
    var charging: Bool
    var activity: Activity
    var connected: Bool
    var updated: Date

    static let widgetKind = "BeeStatus"
    static let placeholder = BeeSnapshot(name: "Bee", battery: 82, charging: false, activity: .listening, connected: true, updated: .now)

    /// Equal apart from the timestamp, so the app doesn't reload the widget for nothing.
    func sameContent(as other: BeeSnapshot?) -> Bool {
        guard var other else { return false }
        other.updated = updated
        return self == other
    }

    private static let key = "snapshot"

    private static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BeeAppGroup") as? String, !group.isEmpty else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func load() -> BeeSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BeeSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        BeeSnapshot.defaults?.set(data, forKey: BeeSnapshot.key)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
