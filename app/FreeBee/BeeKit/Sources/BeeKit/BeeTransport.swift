import BeeProtocol
import Foundation

/// The two Bee characteristics the app uses, over whatever carries them: CoreBluetooth or the simulator.
@MainActor
public protocol BeeTransport: AnyObject {
    /// Control-channel notifications (status responses and events).
    var controlHandler: ((Data) -> Void)? { get set }
    /// SMP-channel notifications. A reply can span several.
    var smpHandler: ((Data) -> Void)? { get set }
    /// Audio-characteristic notifications: `uint32 BE seq` + AES-128-CTR ciphertext.
    var audioHandler: ((Data) -> Void)? { get set }
    /// The largest notification the link carries (ATT MTU minus 3).
    var maximumNotificationLength: Int { get }

    /// Write-with-response on the control characteristic.
    func writeControl(_ data: Data) async throws
    /// Write-without-response on the SMP characteristic.
    func writeSMP(_ data: Data) async throws
    func setSMPNotifications(_ enabled: Bool) async throws
    func setAudioNotifications(_ enabled: Bool) async throws
    func readRSSI() async throws -> Int
}

public enum BeeError: Error, LocalizedError, Equatable {
    /// The device answered with Error, InvalidParam or UnknownMessage.
    case rejected(Command, Message)
    case timeout(Command)
    case smpTimeout
    case disconnected
    case missingCharacteristic(String)
    case bluetooth(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case let .rejected(command, message):
            "The Bee answered \(command) with \(message.name)."
        case let .timeout(command):
            "The Bee didn't answer \(command) in time."
        case .smpTimeout:
            "The Bee didn't answer the firmware query in time."
        case .disconnected:
            "The Bee disconnected."
        case let .missingCharacteristic(uuid):
            "The Bee doesn't expose characteristic \(uuid)."
        case let .bluetooth(reason):
            reason
        case let .invalidValue(reason):
            reason
        }
    }

    /// The device doesn't know this command (for example GetDSN on legacy hardware).
    public var isUnknownMessage: Bool {
        if case let .rejected(_, message) = self { return message.status == .unknownMessage }
        return false
    }
}

/// Lets one async operation through at a time, in arrival order.
@MainActor
final class SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
