import BeeProtocol
@preconcurrency import CoreBluetooth
import Foundation

/// A connected `CBPeripheral` as a `BeeTransport`: finds the control, audio and SMP characteristics,
/// subscribes to control notifications and turns delegate callbacks into async calls.
@MainActor
public final class BluetoothTransport: NSObject, BeeTransport {
    public static let setupTimeout: Duration = .seconds(15)

    public let peripheral: CBPeripheral
    public var controlHandler: ((Data) -> Void)?
    public var smpHandler: ((Data) -> Void)?
    public var audioHandler: ((Data) -> Void)?

    private let controlUUID = CBUUID(string: BeeGATT.controlCharacteristic)
    private let smpUUID = CBUUID(string: BeeGATT.smpCharacteristic)
    private let audioUUID = CBUUID(string: BeeGATT.audioCharacteristic)
    private var control: CBCharacteristic?
    private var smp: CBCharacteristic?
    private var audio: CBCharacteristic?

    /// One continuation per kind of pending operation. The control channel and SMP client already
    /// serialize their own requests, so there's at most one of each in flight.
    private var discovery: CheckedContinuation<Void, Error>?
    private var notifyChanges: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var controlWrite: CheckedContinuation<Void, Error>?
    private var rssiRead: CheckedContinuation<Int, Error>?
    private var readyToSend: [CheckedContinuation<Void, Never>] = []
    private var pendingServices = 0
    private var invalidated: BeeError?

    public init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    /// Discovers services and characteristics, then enables control notifications. On first contact
    /// this is also where iOS bonds with the Bee (the characteristics need an encrypted link).
    public func prepare() async throws {
        try checkValid()
        if control == nil || smp == nil {
            try await withTimeout(BluetoothTransport.setupTimeout) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.discovery = continuation
                    self.peripheral.discoverServices([BeeCentral.controlService, CBUUID(string: BeeGATT.smpService)])
                }
            } onTimeout: {
                self.fail(&self.discovery, BeeError.bluetooth("Timed out discovering the Bee's services."))
            }
        }
        guard let control else { throw BeeError.missingCharacteristic(BeeGATT.controlCharacteristic) }
        if !control.isNotifying {
            try await setNotify(true, for: control)
        }
    }

    /// Fails everything pending. Call when the peripheral disconnects.
    public func invalidate(_ error: BeeError = .disconnected) {
        invalidated = error
        fail(&discovery, error)
        fail(&controlWrite, error)
        if let rssiRead {
            self.rssiRead = nil
            rssiRead.resume(throwing: error)
        }
        for (_, continuation) in notifyChanges { continuation.resume(throwing: error) }
        notifyChanges.removeAll()
        readyToSend.forEach { $0.resume() }
        readyToSend.removeAll()
    }

    // MARK: BeeTransport

    public func writeControl(_ data: Data) async throws {
        try checkValid()
        guard let control else { throw BeeError.missingCharacteristic(BeeGATT.controlCharacteristic) }
        guard controlWrite == nil else { throw BeeError.bluetooth("A control write is already in flight.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlWrite = continuation
            peripheral.writeValue(data, for: control, type: .withResponse)
        }
    }

    public func writeSMP(_ data: Data) async throws {
        try checkValid()
        guard let smp else { throw BeeError.missingCharacteristic(BeeGATT.smpCharacteristic) }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard data.count <= limit else { throw BeeError.bluetooth("SMP request (\(data.count) bytes) exceeds the MTU (\(limit)).") }
        while !peripheral.canSendWriteWithoutResponse {
            await withCheckedContinuation { readyToSend.append($0) }
            try checkValid()
        }
        peripheral.writeValue(data, for: smp, type: .withoutResponse)
    }

    public func setSMPNotifications(_ enabled: Bool) async throws {
        try checkValid()
        guard let smp else { throw BeeError.missingCharacteristic(BeeGATT.smpCharacteristic) }
        guard smp.isNotifying != enabled else { return }
        try await setNotify(enabled, for: smp)
    }

    public func setAudioNotifications(_ enabled: Bool) async throws {
        try checkValid()
        guard let audio else { throw BeeError.missingCharacteristic(BeeGATT.audioCharacteristic) }
        guard audio.isNotifying != enabled else { return }
        try await setNotify(enabled, for: audio)
    }

    public var maximumNotificationLength: Int { peripheral.maximumWriteValueLength(for: .withoutResponse) }

    public func readRSSI() async throws -> Int {
        try checkValid()
        if let rssiRead {
            self.rssiRead = nil
            rssiRead.resume(throwing: BeeError.bluetooth("RSSI read superseded."))
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            rssiRead = continuation
            peripheral.readRSSI()
        }
    }

    // MARK: helpers

    private func checkValid() throws {
        if let invalidated { throw invalidated }
        guard peripheral.state == .connected else { throw BeeError.disconnected }
    }

    private func setNotify(_ enabled: Bool, for characteristic: CBCharacteristic) async throws {
        let uuid = characteristic.uuid
        try await withTimeout(BluetoothTransport.setupTimeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.notifyChanges[uuid] = continuation
                self.peripheral.setNotifyValue(enabled, for: characteristic)
            }
        } onTimeout: {
            if let continuation = self.notifyChanges.removeValue(forKey: uuid) {
                continuation.resume(throwing: BeeError.bluetooth("Timed out subscribing to the Bee. If iOS asked to pair, accept it."))
            }
        }
    }

    private func fail<T>(_ slot: inout CheckedContinuation<T, Error>?, _ error: Error) {
        guard let continuation = slot else { return }
        slot = nil
        continuation.resume(throwing: error)
    }

    /// Runs `body`; if it hasn't finished after `timeout`, calls `onTimeout`, which must make `body` throw.
    private func withTimeout(
        _ timeout: Duration,
        _ body: () async throws -> Void,
        onTimeout: @escaping @MainActor () -> Void
    ) async throws {
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { onTimeout() }
        }
        defer { timer.cancel() }
        try await body()
    }

    private static func describe(_ error: Error) -> BeeError {
        if let error = error as? CBATTError {
            switch error.code {
            case .insufficientAuthentication, .insufficientEncryption, .insufficientAuthorization:
                return .bluetooth("The Bee refused an unpaired connection. Put it in pairing mode (press 5 times) and try again.")
            default:
                break
            }
        }
        return .bluetooth(error.localizedDescription)
    }
}

extension BluetoothTransport: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail(&discovery, BluetoothTransport.describe(error))
            return
        }
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == BeeCentral.controlService }) else {
            fail(&discovery, BeeError.bluetooth("This doesn't look like a Bee: no control service."))
            return
        }
        pendingServices = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            fail(&discovery, BluetoothTransport.describe(error))
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == controlUUID { control = characteristic }
            if characteristic.uuid == smpUUID { smp = characteristic }
            if characteristic.uuid == audioUUID { audio = characteristic }
        }
        pendingServices -= 1
        guard pendingServices <= 0, let discovery else { return }
        self.discovery = nil
        if control == nil {
            discovery.resume(throwing: BeeError.missingCharacteristic(BeeGATT.controlCharacteristic))
        } else {
            discovery.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case controlUUID: controlHandler?(Data(value))
        case smpUUID: smpHandler?(Data(value))
        case audioUUID: audioHandler?(Data(value))
        default: break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == controlUUID, let controlWrite else { return }
        self.controlWrite = nil
        if let error {
            controlWrite.resume(throwing: BluetoothTransport.describe(error))
        } else {
            controlWrite.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let continuation = notifyChanges.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            continuation.resume(throwing: BluetoothTransport.describe(error))
        } else {
            continuation.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let rssiRead else { return }
        self.rssiRead = nil
        if let error {
            rssiRead.resume(throwing: BluetoothTransport.describe(error))
        } else {
            rssiRead.resume(returning: RSSI.intValue)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let waiting = readyToSend
        readyToSend.removeAll()
        waiting.forEach { $0.resume() }
    }
}
