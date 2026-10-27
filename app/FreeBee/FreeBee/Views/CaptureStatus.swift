import BeeKit
import BeeProtocol
import SwiftUI

/// The one answer to "is what I'm saying being saved?". It joins the Bee's state, the Bluetooth link and
/// whether audio is actually arriving, which can disagree: the Bee's light can be green while nothing
/// reaches this iPhone.
struct CaptureStatus: Equatable {
    enum Kind: Equatable {
        /// Verified audio is arriving and being saved.
        case recording(since: Date)
        /// The Bee is set to record and the first audio hasn't arrived yet.
        case starting
        /// The Bee says it's recording, but audio stopped arriving.
        case stalled
        case muted
        case asleep
        case off
        case needsKey
        /// Not connected. `listening`: the Bee was set to record when it was last seen.
        case away(listening: Bool)
        case connecting
        case unavailable(String)
    }

    var kind: Kind

    @MainActor
    init(_ store: BeeStore, now: Date = .now) {
        switch store.link {
        case .unpaired, .searching:
            kind = store.status.state == .powerOff ? .off : .away(listening: store.captureWanted)
        case .connecting:
            kind = .connecting
        case let .unavailable(reason):
            kind = .unavailable(reason)
        case .ready:
            if !store.hasKeyForThisBee && !store.sessionOpen && !store.isDemo {
                kind = .needsKey
                return
            }
            switch store.status.state {
            case .recording:
                if let since = store.capturingSince {
                    kind = .recording(since: since)
                } else if let last = store.capture.lastFrame, store.capture.verified, now.timeIntervalSince(last) > 15 {
                    kind = .stalled
                } else {
                    kind = .starting
                }
            case .sleepHardwareVAD, .sleepSoftwareVAD: kind = .asleep
            case .powerOff: kind = .off
            default: kind = .muted
            }
        }
    }

    var title: String {
        switch kind {
        case .recording: "Recording"
        case .starting: "Starting"
        case .stalled: "Not saving"
        case .muted: "Muted"
        case .asleep: "Asleep"
        case .off: "Off"
        case .needsKey: "Needs the audio key"
        case .away: "Not connected"
        case .connecting: "Connecting"
        case .unavailable: "Bluetooth is off"
        }
    }

    /// One plain sentence under the title. Recording shows a running timer instead.
    var detail: String {
        switch kind {
        case .recording: "Saving to this iPhone"
        case .starting: "Waiting for the first audio."
        case .stalled: "Your Bee is listening, but no audio is arriving. FreeBee keeps trying."
        case .muted: "Press your Bee's button or tap Unmute to record."
        case .asleep: "Tap Unmute to wake it and record."
        case .off: "Turn it on at the Bee. This iPhone reconnects when it's back."
        case .needsKey: "Recording needs this Bee's pairing token from the Mac."
        case .away(listening: true): "Your Bee may still be listening, but nothing is saved until it's back in range."
        case .away(listening: false): "It reconnects by itself when it's on and nearby."
        case .connecting: "Your Bee is nearby."
        case let .unavailable(reason): reason
        }
    }

    /// The light we draw on the Bee: green whenever the Bee itself is recording, like the real one.
    var light: Color? {
        switch kind {
        case .recording, .starting, .stalled: .recording
        default: nil
        }
    }

    var isLive: Bool {
        if case .recording = kind { return true }
        return false
    }

    /// Something is wrong that the person should notice.
    var isWarning: Bool {
        switch kind {
        case .stalled, .away(listening: true), .unavailable: true
        default: false
        }
    }

    var isConnected: Bool {
        switch kind {
        case .away, .connecting, .unavailable, .off: false
        default: true
        }
    }

    /// The main button: stop or start recording, or get the key that recording needs.
    enum Action { case mute, unmute, importKey }

    var action: Action? {
        switch kind {
        case .recording, .starting, .stalled: .mute
        case .muted, .asleep: .unmute
        case .needsKey: .importKey
        default: nil
        }
    }
}
