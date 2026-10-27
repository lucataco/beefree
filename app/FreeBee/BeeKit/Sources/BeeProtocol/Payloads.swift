import Foundation

/// Legacy Bees advertise company id 0xBEEE; newer "Frontier" ones use 0xBEEF and report battery in millivolts.
public enum Hardware: String, Codable, Hashable, Sendable {
    case legacy
    case frontier

    /// Frontier boards report hardware revision 3 (Frontier C) or 4 (Frontier D).
    public init?(revision: Int) {
        switch revision {
        case 3, 4: self = .frontier
        case 0...2: self = .legacy
        default: return nil
        }
    }
}

public enum DeviceState: Hashable, Sendable {
    case mute
    case recording
    /// Sleep with hardware voice-activity detection.
    case sleepHardwareVAD
    case powerOff
    /// Sleep with software voice-activity detection.
    case sleepSoftwareVAD
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .mute
        case 1: self = .recording
        case 2: self = .sleepHardwareVAD
        case 3: self = .powerOff
        case 4: self = .sleepSoftwareVAD
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .mute: 0
        case .recording: 1
        case .sleepHardwareVAD: 2
        case .powerOff: 3
        case .sleepSoftwareVAD: 4
        case let .unknown(value): value
        }
    }

    /// The name beekit prints (`sleep_hw_vad`, ...).
    public var protocolName: String {
        switch self {
        case .mute: "mute"
        case .recording: "recording"
        case .sleepHardwareVAD: "sleep_hw_vad"
        case .powerOff: "power_off"
        case .sleepSoftwareVAD: "sleep_sw_vad"
        case let .unknown(value): String(value)
        }
    }

    /// Mute and recording only stick inside a session opened with SetEncryptionKey.
    public var needsSession: Bool { self == .mute || self == .recording }

    public var isSleep: Bool { self == .sleepHardwareVAD || self == .sleepSoftwareVAD }
}

public enum Codec: Hashable, Sendable {
    case opus
    case aac
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .opus
        case 1: self = .aac
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .opus: 0
        case .aac: 1
        case let .unknown(value): value
        }
    }

    public var protocolName: String {
        switch self {
        case .opus: "opus"
        case .aac: "aac"
        case let .unknown(value): String(value)
        }
    }
}

public struct FirmwareVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var hardwareRevision: Int?

    /// The newest build reported publicly (jkmills/bee-wearable-ble). Ours runs 0.6.1.
    public static let newestPublic = FirmwareVersion(major: 0, minor: 6, patch: 5)

    public init(major: Int, minor: Int, patch: Int, hardwareRevision: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.hardwareRevision = hardwareRevision
    }

    /// GetFirmwareVersion data: `[patch, minor, major, ?, hw_rev?]`.
    public init(payload: Data) throws {
        let b = [UInt8](payload)
        guard b.count >= 3 else { throw ProtocolError.tooShort("firmware version payload", payload) }
        self.init(major: Int(b[2]), minor: Int(b[1]), patch: Int(b[0]), hardwareRevision: b.count >= 5 ? Int(b[4]) : nil)
    }

    /// Parses "0.6.1" (as SMP reports image versions; a trailing build number is ignored).
    public init?(_ text: String) {
        let parts = text.split(separator: ".").prefix(3).compactMap { Int($0.prefix { $0.isNumber }) }
        guard parts.count == 3 else { return nil }
        self.init(major: parts[0], minor: parts[1], patch: parts[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public static func == (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        (a.major, a.minor, a.patch) == (b.major, b.minor, b.patch)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }
}

public struct Battery: Hashable, Sendable {
    public var percent: Int
    public var charging: Bool
    /// Frontier only. Its percentage is our estimate from this voltage.
    public var millivolts: Int?

    public init(percent: Int, charging: Bool, millivolts: Int? = nil) {
        self.percent = percent
        self.charging = charging
        self.millivolts = millivolts
    }

    /// GetBattery data. Legacy: `[percent, charging]` (confirmed on ours).
    /// Frontier (untested): `LE16 millivolts, charging raw`.
    public init(payload: Data, hardware: Hardware = .legacy) throws {
        let b = [UInt8](payload)
        switch hardware {
        case .legacy:
            guard b.count >= 2 else { throw ProtocolError.tooShort("battery payload", payload) }
            self.init(percent: Int(b[0]), charging: b[1] != 0)
        case .frontier:
            guard b.count >= 3 else { throw ProtocolError.tooShort("battery payload", payload) }
            let mv = Int(b.le16(at: 0))
            self.init(percent: Battery.estimatePercent(millivolts: mv), charging: b[2] != 0, millivolts: mv)
        }
    }

    /// Bee's own millivolt curve wasn't decompiled, so this is a generic single-cell LiPo curve.
    public static func estimatePercent(millivolts mv: Int) -> Int {
        let curve: [(mv: Int, percent: Int)] = [
            (3270, 0), (3610, 5), (3690, 10), (3710, 15), (3730, 20), (3750, 25), (3770, 30), (3790, 35),
            (3800, 40), (3820, 45), (3840, 50), (3850, 55), (3870, 60), (3910, 65), (3950, 70), (3980, 75),
            (4020, 80), (4080, 85), (4110, 90), (4150, 95), (4200, 100),
        ]
        guard mv > curve[0].mv else { return 0 }
        for (low, high) in zip(curve, curve.dropFirst()) where mv <= high.mv {
            let fraction = Double(mv - low.mv) / Double(high.mv - low.mv)
            return low.percent + Int((fraction * Double(high.percent - low.percent)).rounded())
        }
        return 100
    }
}

/// Battery level from the A004 event: legacy `[percent]`, Frontier `LE16 millivolts`.
public struct BatteryLevel: Hashable, Sendable {
    public var percent: Int
    public var millivolts: Int?

    public init(percent: Int, millivolts: Int? = nil) {
        self.percent = percent
        self.millivolts = millivolts
    }

    public init?(eventPayload payload: Data, hardware: Hardware = .legacy) {
        let b = [UInt8](payload)
        if hardware == .frontier, b.count >= 2 {
            let mv = Int(b.le16(at: 0))
            self.init(percent: Battery.estimatePercent(millivolts: mv), millivolts: mv)
        } else if let first = b.first {
            self.init(percent: Int(first))
        } else {
            return nil
        }
    }
}

/// GetDeviceState data and the A003 event: `[state, codec]`.
public struct DeviceStatus: Hashable, Sendable {
    public var state: DeviceState
    public var codec: Codec?

    public init(state: DeviceState, codec: Codec? = nil) {
        self.state = state
        self.codec = codec
    }

    public init(payload: Data) throws {
        let b = [UInt8](payload)
        guard let first = b.first else { throw ProtocolError.tooShort("device state payload", payload) }
        self.init(state: DeviceState(rawValue: first), codec: b.count >= 2 ? Codec(rawValue: b[1]) : nil)
    }
}

public enum DeviceID {
    /// Bee's device-id string: LE32 of bytes 4-7, then LE32 of bytes 0-3, as 16 uppercase hex digits.
    /// GetDeviceID returns the same 8 bytes the advertisement carries.
    public static func format(_ raw: Data) throws -> String {
        let b = [UInt8](raw)
        guard b.count >= 8 else { throw ProtocolError.tooShort("device id", raw) }
        return String(format: "%08X%08X", b.le32(at: 4), b.le32(at: 0))
    }
}

/// GetSecureIds data: 8 id bytes, then the sealed flag.
public struct SecureIDs: Hashable, Sendable {
    public var deviceID: String
    public var sealed: Bool?

    public init(payload: Data) throws {
        deviceID = try DeviceID.format(payload)
        let b = [UInt8](payload)
        sealed = b.count >= 9 ? b[8] != 0 : nil
    }
}

public enum DSN {
    public static func parse(_ payload: Data) -> String {
        var b = [UInt8](payload)
        while let last = b.last, last == 0x00 || last == 0xFF { b.removeLast() }
        return String(decoding: b.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }
}

/// A device-to-phone event (A001-A005). Events carry no echoed command id.
public enum BeeEvent: Hashable, Sendable, CustomStringConvertible {
    case doublePress
    case hold(pressed: Bool)
    case state(DeviceStatus)
    case battery(BatteryLevel)
    case charging(Bool)
    case other(code: UInt16, payload: Data)

    public init(_ message: Message, hardware: Hardware = .legacy) {
        let d = message.payload
        switch message.event {
        case .buttonDoublePress:
            self = .doublePress
        case .buttonHold:
            self = .hold(pressed: d.first == 1)
        case .deviceState:
            if let status = try? DeviceStatus(payload: d) { self = .state(status) } else { self = .other(code: message.code, payload: d) }
        case .battery:
            if let level = BatteryLevel(eventPayload: d, hardware: hardware) { self = .battery(level) } else { self = .other(code: message.code, payload: d) }
        case .charging:
            self = .charging((d.first ?? 0) != 0)
        case nil:
            self = .other(code: message.code, payload: d)
        }
    }

    /// Same wording as `beekit watch`.
    public var description: String {
        switch self {
        case .doublePress: "button: double press"
        case let .hold(pressed): pressed ? "button: hold" : "button: release"
        case let .state(status): "state: \(status.state.protocolName) (codec \(status.codec?.protocolName ?? "?"))"
        case let .battery(level): "battery: \(level.percent)%"
        case let .charging(on): on ? "charging: yes" : "charging: no"
        case let .other(code, payload): "\(Message(code: code, command: nil, payload: payload).name): \(payload.hex)"
        }
    }
}
