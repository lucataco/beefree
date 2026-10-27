import ActivityKit
import AppIntents
import Foundation

/// The recording light: a Live Activity for as long as the Bee is set to listen. Bluetooth audio doesn't
/// turn on iOS's microphone indicator, so this is how you (and the people around you) can see it's on,
/// and it puts Mute one tap away on the Lock Screen and in the Dynamic Island.
nonisolated struct CaptureActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            /// Verified audio is arriving.
            case capturing
            /// Connected and set to listen, waiting for audio.
            case waiting
            /// Set to listen, but the Bee isn't connected: nothing is being captured.
            case disconnected
        }

        var phase: Phase
        /// When the current stretch of capture began; the timer counts from here.
        var since: Date
    }

    var name: String
}

/// Mute from the Live Activity. A `LiveActivityIntent` runs in the app's process, so the app supplies the
/// handler; the widget extension only needs the type to draw the button.
struct MuteFromActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute Bee"
    static let isDiscoverable = false

    @MainActor static var handler: (@MainActor () async throws -> Void)?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await Self.handler?()
        return .result()
    }
}
