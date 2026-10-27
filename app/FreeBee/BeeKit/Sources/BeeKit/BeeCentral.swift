import BeeProtocol
@preconcurrency import CoreBluetooth
import Foundation

/// A Bee seen while scanning (plain CoreBluetooth pairing only).
public struct BeeDiscovery: Identifiable {
    public let peripheral: CBPeripheral
    public let name: String?
    public let rssi: Int
    public let advertisement: Advertisement?
    public let seen: Date

    public var id: UUID { peripheral.identifier }
}

/// Wraps `CBCentralManager`: state, scanning, connecting and background state restoration.
/// Runs on the main queue; callbacks arrive through `onEvent`.
@MainActor
public final class BeeCentral: NSObject {
    public enum Event {
        case stateChanged(CBManagerState)
        /// Peripherals iOS was holding for us when it relaunched the app in the background.
        case restored([CBPeripheral])
        case discovered(BeeDiscovery)
        case connected(CBPeripheral)
        case failedToConnect(CBPeripheral, Error?)
        case disconnected(CBPeripheral, Error?)
    }

    public nonisolated static let controlService = CBUUID(string: BeeGATT.controlService)
    public nonisolated static let advertisedService = CBUUID(string: BeeGATT.advertisedService)

    public var onEvent: ((Event) -> Void)?
    public private(set) var isScanning = false

    private var manager: CBCentralManager!

    /// - Parameter restoreIdentifier: enables state restoration (iOS), so a pending connection or
    ///   subscribed notification can relaunch the app after iOS has terminated it.
    public init(restoreIdentifier: String? = nil) {
        super.init()
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        #if os(iOS)
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        #endif
        manager = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    public var state: CBManagerState { manager.state }

    public func retrievePeripheral(_ identifier: UUID) -> CBPeripheral? {
        manager.retrievePeripherals(withIdentifiers: [identifier]).first
    }

    /// Bees the system already has a link to (for example after the app was relaunched).
    public func connectedBees() -> [CBPeripheral] {
        manager.retrieveConnectedPeripherals(withServices: [BeeCentral.controlService])
    }

    /// Foreground scan. Filters by Bee's company ids, advertised service or name.
    public func startScan() {
        guard manager.state == .poweredOn else { return }
        isScanning = true
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    public func stopScan() {
        isScanning = false
        if manager.state == .poweredOn { manager.stopScan() }
    }

    /// Connection requests don't time out: iOS completes them whenever the Bee shows up, even in the background.
    public func connect(_ peripheral: CBPeripheral) {
        guard manager.state == .poweredOn else { return }
        manager.connect(peripheral, options: nil)
    }

    public func cancel(_ peripheral: CBPeripheral) {
        guard manager.state == .poweredOn else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    nonisolated static func isBee(name: String?, advertisementData: [String: Any]) -> Bool {
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           Advertisement.isBeeManufacturerData(data) {
            return true
        }
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(advertisedService) {
            return true
        }
        let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? name
        return local == BeeGATT.advertisedName
    }
}

extension BeeCentral: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { isScanning = false }
        onEvent?(.stateChanged(central.state))
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        #if os(iOS)
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        onEvent?(.restored(peripherals))
        #endif
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard BeeCentral.isBee(name: peripheral.name, advertisementData: advertisementData) else { return }
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let rssi = RSSI.intValue
        onEvent?(.discovered(BeeDiscovery(
            peripheral: peripheral,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
            rssi: rssi == 127 ? -100 : rssi,  // 127 means "unavailable"
            advertisement: manufacturer.flatMap(Advertisement.parse(manufacturerData:)),
            seen: Date()
        )))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onEvent?(.connected(peripheral))
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onEvent?(.failedToConnect(peripheral, error))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onEvent?(.disconnected(peripheral, error))
    }
}
