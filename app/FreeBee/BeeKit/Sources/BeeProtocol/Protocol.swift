import Foundation

// Bee wearable BLE protocol: UUIDs, command ids and control-channel framing.
// A Swift port of mac/src/beekit/protocol.py. IDs and layouts come from jkmills/bee-wearable-ble (MIT)
// and were checked against our unit (legacy hardware, firmware 0.6.1). See docs/PROTOCOL.md.

/// GATT and advertisement identifiers.
public enum BeeGATT {
    public static let advertisedName = "Bee"
    /// 16-bit service in the advertisement. The 128-bit control service is only visible after connecting.
    public static let advertisedService = "D5C4"
    public static let controlService = "03D5D5C4-A86C-11EE-9D89-8F2089A49E7E"
    /// write, write-without-response, notify
    public static let controlCharacteristic = "05E1F93C-D8D0-5ED8-DD88-379E4C1A3E3E"
    /// notify only (encrypted audio)
    public static let audioCharacteristic = "B189A505-A86C-11EE-A5FB-8F2089A49E7E"
    /// MCUmgr (Zephyr / MCUboot)
    public static let smpService = "8D53DC1D-1DB7-4CD3-868B-8A527460AA84"
    public static let smpCharacteristic = "DA2E7828-FBCE-4E01-AE9E-261174997C48"
}

public enum CompanyID {
    public static let legacy: UInt16 = 0xBEEE
    public static let frontier: UInt16 = 0xBEEF
}

public enum Command: UInt16, CaseIterable, Sendable, CustomStringConvertible {
    case setTxPower = 0xC001
    case getTxLevel = 0xC002
    case getChargingSpeed = 0xC004
    case getFirmwareVersion = 0xC005
    case setDeviceState = 0xC006
    case setBitrate = 0xC008
    case getBitrate = 0xC009
    case getDeviceState = 0xC00A
    case getDeviceID = 0xC00E
    case getBattery = 0xC00F
    case setBrightness = 0xC016
    case getBrightness = 0xC017
    case setEncryptionKey = 0xC018
    case getSessionNonce = 0xC019
    case getSecureIDs = 0xC01B
    case getDSN = 0xC01D

    public var description: String {
        switch self {
        case .setTxPower: "SetTxPower"
        case .getTxLevel: "GetTxLevel"
        case .getChargingSpeed: "GetChargingSpeed"
        case .getFirmwareVersion: "GetFirmwareVersion"
        case .setDeviceState: "SetDeviceState"
        case .setBitrate: "SetBitrate"
        case .getBitrate: "GetBitrate"
        case .getDeviceState: "GetDeviceState"
        case .getDeviceID: "GetDeviceID"
        case .getBattery: "GetBattery"
        case .setBrightness: "SetBrightness"
        case .getBrightness: "GetBrightness"
        case .setEncryptionKey: "SetEncryptionKey"
        case .getSessionNonce: "GetSessionNonce"
        case .getSecureIDs: "GetSecureIds"
        case .getDSN: "GetDSN"
        }
    }
}

public enum ResponseStatus: UInt16, Sendable, CustomStringConvertible {
    case ok = 0x8000
    case error = 0x8001
    case invalidParam = 0x8002
    case unknownMessage = 0x8003
    /// SetEncryptionKey re-key acknowledgement
    case keyAccepted = 0x8004

    public var description: String {
        switch self {
        case .ok: "OK"
        case .error: "Error"
        case .invalidParam: "InvalidParam"
        case .unknownMessage: "UnknownMessage"
        case .keyAccepted: "KeyAccepted"
        }
    }
}

public enum EventCode: UInt16, Sendable, CustomStringConvertible {
    case buttonDoublePress = 0xA001
    case buttonHold = 0xA002
    case deviceState = 0xA003
    case battery = 0xA004
    case charging = 0xA005

    public var description: String {
        switch self {
        case .buttonDoublePress: "ButtonDoublePress"
        case .buttonHold: "ButtonHold"
        case .deviceState: "DeviceState"
        case .battery: "Battery"
        case .charging: "Charging"
        }
    }
}

public enum ProtocolError: Error, Hashable, CustomStringConvertible {
    case tooShort(String, Data)
    case notAToken
    case unreadableKeyFile(String)
    case badAudioKey(Int)
    case badNonce(Data)
    case crypto(Int32)

    public var description: String {
        switch self {
        case let .tooShort(what, data): "\(what) too short: \(data.hex)"
        case .notAToken: "not a SKV1 SetEncryptionKey token"
        case let .unreadableKeyFile(reason): "unreadable key file: \(reason)"
        case let .badAudioKey(length): "the audio key has to be 16 bytes, not \(length)"
        case let .badNonce(nonce): "the session nonce has to be 12 bytes: \(nonce.hex)"
        case let .crypto(status): "CommonCrypto error \(status)"
        }
    }
}

/// One control-characteristic notification from the device.
public struct Message: Hashable, Sendable, CustomStringConvertible {
    public let code: UInt16
    /// Request id echoed back by status responses; nil for events.
    public let command: UInt16?
    public let payload: Data

    public init(code: UInt16, command: UInt16?, payload: Data) {
        self.code = code
        self.command = command
        self.payload = payload
    }

    public var status: ResponseStatus? { ResponseStatus(rawValue: code) }
    public var event: EventCode? { EventCode(rawValue: code) }
    public var isEvent: Bool { (0xA000..<0xB000).contains(code) }
    public var ok: Bool { status == .ok || status == .keyAccepted }

    public var name: String {
        if let status { return status.description }
        if let event { return event.description }
        return String(format: "0x%04X", code)
    }

    public var description: String {
        let echoed = command.map { Command(rawValue: $0)?.description ?? String(format: "0x%04X", $0) }
        return [name, echoed, payload.isEmpty ? nil : payload.hex].compactMap { $0 }.joined(separator: " ")
    }
}

public enum Frame {
    /// Control-characteristic write: little-endian uint16 command id, then payload.
    public static func encode(_ command: Command, _ payload: Data = Data()) -> Data {
        encode(code: command.rawValue, payload)
    }

    public static func encode(code: UInt16, _ payload: Data = Data()) -> Data {
        Data(code.littleEndianBytes) + payload
    }

    public static func decode(_ data: Data) throws -> Message {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw ProtocolError.tooShort("control message", data) }
        let code = bytes.le16(at: 0)
        let rest = Array(bytes[2...])
        if ResponseStatus(rawValue: code) != nil, rest.count >= 2 {
            return Message(code: code, command: rest.le16(at: 0), payload: Data(rest[2...]))
        }
        return Message(code: code, command: nil, payload: Data(rest))
    }
}
