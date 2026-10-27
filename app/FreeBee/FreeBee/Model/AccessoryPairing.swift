import AccessorySetupKit
import BeeProtocol
import CoreBluetooth
import UIKit

/// AccessorySetupKit pairing: the system picker finds the Bee in pairing mode and authorizes this app
/// for it. CoreBluetooth then sees only that accessory, with no Bluetooth permission prompt.
final class AccessoryPairing {
    enum Event {
        case activated([ASAccessory])
        case added(ASAccessory)
        case removed(ASAccessory)
        case pickerDismissed
        case setupFailed(Error?)
    }

    /// The Bee bonds on its first connection, so let the picker handle LE pairing during setup.
    static let supportOptions: ASAccessory.SupportOptions = [.bluetoothPairingLE]

    var onEvent: ((Event) -> Void)?

    private let session = ASAccessorySession()

    func activate() {
        session.activate(on: .main) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func accessory(for bluetoothIdentifier: UUID) -> ASAccessory? {
        session.accessories.first { $0.bluetoothIdentifier == bluetoothIdentifier }
    }

    /// Only call in response to a tap.
    func showPicker(completion: @escaping (Error?) -> Void) {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(string: BeeGATT.advertisedService)
        descriptor.supportedOptions = AccessoryPairing.supportOptions
        let item = ASPickerDisplayItem(name: "Bee", productImage: BeeArtwork.pickerImage(), descriptor: descriptor)
        session.showPicker(for: [item]) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func remove(_ accessory: ASAccessory) async throws {
        try await session.removeAccessory(accessory)
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            onEvent?(.activated(session.accessories))
        case .accessoryAdded:
            if let accessory = event.accessory { onEvent?(.added(accessory)) }
        case .accessoryRemoved:
            if let accessory = event.accessory { onEvent?(.removed(accessory)) }
        case .pickerDidDismiss:
            onEvent?(.pickerDismissed)
        case .pickerSetupFailed:
            onEvent?(.setupFailed(event.error))
        default:
            break
        }
    }
}
