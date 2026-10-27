import BeeProtocol
import Foundation

/// One connection's audio path: subscribe → decrypt → reassemble → append to the recorder.
///
/// A connection isn't "capturing" until frames that decrypt and chain arrive (with the wrong key or
/// nonce they never do), so `isVerified` is the readiness signal, not the subscription.
@MainActor
public final class AudioCapture {
    public struct Status: Hashable, Sendable {
        public var subscribed = false
        public var verified = false
        public var stats = AudioStream.Stats()
        public var lastFrame: Date?
        public var started: Date?
        /// The largest notification the link carries (ATT MTU minus 3).
        public var maximumNotificationLength = 0
        /// Audio captured on this connection.
        public var seconds: TimeInterval = 0

        public init() {}
    }

    public enum Problem: Equatable, Sendable {
        /// Packets arrive but never decrypt into ADTS: the key or the nonce is wrong.
        case undecryptable(packets: Int)
        case writeFailed(String)
    }

    public let recorder: AudioRecorder
    /// Packets without a single chained frame before reporting `.undecryptable` (about 5 s of audio).
    public var undecryptableAfter = 40
    public private(set) var status = Status()
    public var onStatus: ((Status) -> Void)?
    public var onVerified: (() -> Void)?
    public var onProblem: ((Problem) -> Void)?

    private var stream: AudioStream?
    private var deviceID = ""
    private weak var transport: (any BeeTransport)?
    private var reportedUndecryptable = false
    private var lastStatusPush = Date.distantPast

    public init(recorder: AudioRecorder) {
        self.recorder = recorder
    }

    public var isRunning: Bool { stream != nil }

    /// Call once the session is open (SetEncryptionKey, then GetSessionNonce gave `nonce`).
    public func start(transport: any BeeTransport, key: Data, nonce: Data, deviceID: String) async throws {
        stop(.disconnected)
        stream = try AudioStream(key: key, nonce: nonce)
        self.deviceID = deviceID
        self.transport = transport
        reportedUndecryptable = false
        status = Status()
        status.started = .now
        status.maximumNotificationLength = transport.maximumNotificationLength
        transport.audioHandler = { [weak self] packet in self?.receive(packet) }
        try await transport.setAudioNotifications(true)
        status.subscribed = true
        push(force: true)
    }

    /// Unsubscribes and resubscribes, for when the stream stalls while the Bee says it's recording.
    public func rearm() async throws {
        guard let transport, stream != nil else { return }
        recorder.close(.idle)
        try await transport.setAudioNotifications(false)
        try await transport.setAudioNotifications(true)
    }

    /// The Bee stopped recording, or the link went away. Ends the open segment.
    public func pause(_ reason: AudioRecorder.CloseReason = .stopped) {
        recorder.close(reason)
    }

    public func stop(_ reason: AudioRecorder.CloseReason) {
        recorder.close(reason)
        transport?.audioHandler = nil
        transport = nil
        stream = nil
        status.subscribed = false
        push(force: true)
    }

    /// A one-line link report for the event log.
    public var summary: String {
        let s = status.stats
        var parts = ["\(s.packets) packets", "\(s.frames) frames (\(Self.format(status.seconds)))"]
        if s.lostPackets > 0 { parts.append("\(s.lostPackets) lost (\(String(format: "%.1f", s.lossRate * 100))%)") }
        if s.resyncBytes > 0 { parts.append("\(s.resyncBytes) resync bytes") }
        if s.restarts > 0 { parts.append("\(s.restarts) restarts") }
        if s.packets > 0 { parts.append("packets \(s.minPacket == s.maxPacket ? "\(s.maxPacket)" : "\(s.minPacket)–\(s.maxPacket)") B") }
        parts.append("MTU \(status.maximumNotificationLength + 3)")
        return parts.joined(separator: ", ")
    }

    private func receive(_ packet: Data) {
        guard var stream else { return }
        let lostBefore = stream.stats.lostPackets
        let frames: [Data]
        do {
            frames = try stream.receive(packet)
        } catch {
            return
        }
        self.stream = stream
        status.stats = stream.stats
        let now = Date.now
        if !status.verified, stream.isVerified {
            status.verified = true
            onVerified?()
        }
        if !stream.isVerified, stream.stats.packets >= undecryptableAfter, !reportedUndecryptable {
            reportedUndecryptable = true
            onProblem?(.undecryptable(packets: stream.stats.packets))
        }
        if let format = stream.format {
            do {
                try recorder.append(frames, format: format, deviceID: deviceID, lostPackets: stream.stats.lostPackets - lostBefore, at: now)
            } catch {
                onProblem?(.writeFailed(error.localizedDescription))
            }
            if !frames.isEmpty {
                status.lastFrame = now
                status.seconds += Double(frames.count) * format.frameDuration
            }
        }
        push()
    }

    private func push(force: Bool = false) {
        let now = Date.now
        guard force || now.timeIntervalSince(lastStatusPush) >= 1 else { return }
        lastStatusPush = now
        onStatus?(status)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}
