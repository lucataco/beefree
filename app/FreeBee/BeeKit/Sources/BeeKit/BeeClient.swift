import BeeProtocol
import Foundation

/// A connected Bee: typed reads and writes over the control channel.
@MainActor
public final class BeeClient {
    public let transport: any BeeTransport
    public let channel: ControlChannel
    /// Decides the battery layout. Legacy unless the firmware or advertisement says Frontier.
    public var hardware: Hardware = .legacy
    public var onEvent: ((BeeEvent) -> Void)?

    public init(transport: any BeeTransport) {
        self.transport = transport
        let channel = ControlChannel { [weak transport] data in
            guard let transport else { throw BeeError.disconnected }
            try await transport.writeControl(data)
        }
        self.channel = channel
        transport.controlHandler = { [weak channel] data in channel?.receive(data) }
        channel.onEvent = { [weak self] message in
            guard let self else { return }
            self.onEvent?(BeeEvent(message, hardware: self.hardware))
        }
    }

    public func request(_ command: Command, _ payload: Data = Data()) async throws -> Data {
        try await channel.request(command, payload)
    }

    // MARK: reads

    public func firmwareVersion() async throws -> FirmwareVersion {
        try FirmwareVersion(payload: await request(.getFirmwareVersion))
    }

    public func battery() async throws -> Battery {
        try Battery(payload: await request(.getBattery), hardware: hardware)
    }

    public func deviceStatus() async throws -> DeviceStatus {
        try DeviceStatus(payload: await request(.getDeviceState))
    }

    public func deviceID() async throws -> String {
        try DeviceID.format(await request(.getDeviceID))
    }

    public func secureIDs() async throws -> SecureIDs {
        try SecureIDs(payload: await request(.getSecureIDs))
    }

    public func dsn() async throws -> String {
        DSN.parse(try await request(.getDSN))
    }

    public func txLevel() async throws -> Int {
        let data = try await request(.getTxLevel)
        guard let level = data.first else { throw ProtocolError.tooShort("tx level", data) }
        return Int(level)
    }

    public func bitrate() async throws -> Int {
        let b = [UInt8](try await request(.getBitrate))
        guard b.count >= 4 else { throw ProtocolError.tooShort("bitrate", Data(b)) }
        return Int(Int32(bitPattern: b.le32(at: 0)))
    }

    public func brightness() async throws -> Int {
        let data = try await request(.getBrightness, Data([1]))
        guard let value = data.first else { throw ProtocolError.tooShort("brightness", data) }
        return Int(value)
    }

    public func sessionNonce() async throws -> Data {
        try await request(.getSessionNonce)
    }

    // MARK: writes

    public func setBrightness(_ value: Int) async throws {
        guard (0...100).contains(value) else { throw BeeError.invalidValue("Brightness must be 0-100.") }
        _ = try await request(.setBrightness, Data([1, UInt8(value)]))
    }

    /// Untested for writes on our unit.
    public func setTxPower(_ power: Int) async throws {
        guard let value = Int8(exactly: power) else { throw BeeError.invalidValue("TX power must fit in a signed byte.") }
        _ = try await request(.setTxPower, Data([UInt8(bitPattern: value)]))
    }

    /// Untested for writes on our unit.
    public func setBitrate(_ bitrate: Int) async throws {
        guard let value = Int32(exactly: bitrate), value > 0 else { throw BeeError.invalidValue("Bitrate must be a positive 32-bit number.") }
        _ = try await request(.setBitrate, Data(value.littleEndianBytes))
    }

    /// Mute and recording only stick inside a session (see `openSession`).
    public func setState(_ state: DeviceState) async throws {
        _ = try await request(.setDeviceState, Data([state.rawValue]))
    }

    /// Unlocks this connection with the captured pairing token. Returns the 12-byte session nonce.
    @discardableResult
    public func openSession(_ token: SealedToken) async throws -> Data {
        _ = try await request(.setEncryptionKey, token.raw)
        return try await sessionNonce()
    }
}

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
}

extension Array where Element == UInt8 {
    func le32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
