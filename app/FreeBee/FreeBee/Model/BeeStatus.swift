import BeeProtocol
import Foundation

/// The Bee this app talks to. Outside pairing mode a Bee only accepts the last device it paired with,
/// so there's one at a time.
struct KnownBee: Codable, Equatable {
    var peripheralID: UUID
    var name: String
    var deviceID: String?
    var hardware: Hardware?
    var pairedAt = Date()
    var viaAccessorySetup: Bool
    var isDemo = false

    private static let key = "knownBee"

    static func load() -> KnownBee? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KnownBee.self, from: data)
    }

    static func save(_ bee: KnownBee?) {
        if let bee, let data = try? JSONEncoder().encode(bee) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

enum LinkState: Equatable {
    /// Nothing paired yet.
    case unpaired
    /// Bluetooth is off, unauthorized or unsupported.
    case unavailable(String)
    /// Waiting for the Bee to show up: off, out of range, or paired with another device.
    case searching
    /// Linked, discovering characteristics and reading status.
    case connecting
    case ready

    var label: String {
        switch self {
        case .unpaired: "Not paired"
        case .unavailable: "Bluetooth unavailable"
        case .searching: "Looking for your Bee"
        case .connecting: "Connecting"
        case .ready: "Connected"
        }
    }
}

/// Everything the dashboard shows, read on connect and kept current by events.
struct BeeStatus: Equatable {
    var firmware: FirmwareVersion?
    var hardware: Hardware?
    var deviceID: String?
    var battery: Int?
    var charging: Bool?
    var millivolts: Int?
    var state: DeviceState?
    var codec: Codec?
    var brightness: Int?
    var sealed: Bool?
    var txLevel: Int?
    var bitrate: Int?
    var updated: Date?
}

enum Operation: Hashable {
    case refresh, mute, sleep, power, brightness, firmware, radio
}

struct StoreAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String

    init(_ title: String, _ message: String) {
        self.title = title
        self.message = message
    }

    init(_ title: String, error: Error) {
        self.init(title, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
}

struct StoreError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension DeviceState {
    var title: String {
        switch self {
        case .mute: "Muted"
        case .recording: "Listening"
        case .sleepHardwareVAD, .sleepSoftwareVAD: "Asleep"
        case .powerOff: "Off"
        case let .unknown(value): "State \(value)"
        }
    }

    var detail: String {
        switch self {
        case .mute: "Microphone off"
        case .recording: "Microphone on"
        case .sleepHardwareVAD: "Hardware voice detection"
        case .sleepSoftwareVAD: "Software voice detection"
        case .powerOff: "Powered off"
        case .unknown: "Not in the protocol notes"
        }
    }

    var symbol: String {
        switch self {
        case .mute: "mic.slash.fill"
        case .recording: "waveform"
        case .sleepHardwareVAD, .sleepSoftwareVAD: "moon.zzz.fill"
        case .powerOff: "power"
        case .unknown: "questionmark"
        }
    }

    var activity: BeeSnapshot.Activity {
        switch self {
        case .mute: .muted
        case .recording: .listening
        case .sleepHardwareVAD, .sleepSoftwareVAD: .sleeping
        case .powerOff: .off
        case .unknown: .unknown
        }
    }
}

extension Codec {
    var title: String {
        switch self {
        case .opus: "Opus"
        case .aac: "AAC"
        case let .unknown(value): "Codec \(value)"
        }
    }
}

extension Hardware {
    var title: String {
        switch self {
        case .legacy: "Legacy (0xBEEE)"
        case .frontier: "Frontier (0xBEEF)"
        }
    }
}
