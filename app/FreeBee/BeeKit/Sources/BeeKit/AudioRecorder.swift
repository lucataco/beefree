import BeeProtocol
import Foundation

/// Appends the Bee's audio, unchanged, to ADTS segment files: one file per contiguous run of audio, rolled
/// every 15 minutes. Raw ADTS is 14.4 MB an hour at 32 kbps; decoding or re-encoding here would only cost
/// CPU on the Bluetooth wake path, so everything else happens later, from these files.
///
/// Wall-clock times come from arrival, audio time from the frame count (1024 samples per frame), so the
/// gap between the two is audio that was lost on the way.
@MainActor
public final class AudioRecorder {
    public struct Segment: Hashable, Sendable, Codable, Identifiable {
        public let id: UUID
        public let deviceID: String
        /// Path relative to the recorder's directory.
        public let file: String
        /// When the first frame was captured.
        public let start: Date
        public var lastArrival: Date
        public var frames = 0
        public var bytes = 0
        public var sampleRate: Int
        public var lostPackets = 0

        public var duration: TimeInterval { Double(frames * ADTSHeader.samplesPerFrame) / Double(sampleRate) }
        public var end: Date { start.addingTimeInterval(duration) }
        /// Wall-clock time the segment spans but has no audio for (lost packets, stalls).
        public var missing: TimeInterval { max(0, lastArrival.timeIntervalSince(start) - duration) }
    }

    public enum CloseReason: String, Sendable, Codable {
        /// Reached the segment length; the next frame starts a new one.
        case rolled
        /// No audio for longer than `idleGap`.
        case idle
        /// Recording stopped (muted, asleep).
        case stopped
        case disconnected
    }

    public let directory: URL
    public var segmentLength: TimeInterval = 15 * 60
    /// A pause longer than this ends the segment. The Bee streams continuously while recording, so a pause
    /// means the link stalled or the stream stopped.
    public var idleGap: TimeInterval = 4
    /// Buffered bytes are written at least this often (and when 16 KB are waiting).
    public var flushInterval: TimeInterval = 2

    public var onOpen: ((Segment) -> Void)?
    /// After each write to disk.
    public var onUpdate: ((Segment) -> Void)?
    public var onClose: ((Segment, CloseReason) -> Void)?

    public private(set) var current: Segment?
    private var handle: FileHandle?
    private var pending = Data()
    private var lastFlush = Date.distantPast

    public init(directory: URL) {
        self.directory = directory
    }

    /// Adds the frames one notification completed. `lostPackets` is the number lost since the last call.
    public func append(_ frames: [Data], format: ADTSHeader, deviceID: String, lostPackets: Int = 0, at arrival: Date = .now) throws {
        if let segment = current {
            if arrival.timeIntervalSince(segment.lastArrival) > idleGap {
                close(.idle)
            } else if segment.duration >= segmentLength {
                close(.rolled)
            } else if segment.deviceID != deviceID || segment.sampleRate != format.sampleRate {
                close(.stopped)
            }
        }
        if frames.isEmpty {
            current?.lostPackets += lostPackets
            return
        }
        if current == nil {
            let captured = arrival.addingTimeInterval(-Double(frames.count) * format.frameDuration)
            try open(deviceID: deviceID, sampleRate: format.sampleRate, start: captured, arrival: arrival)
        }
        for frame in frames { pending.append(frame) }
        current?.frames += frames.count
        current?.bytes += frames.reduce(0) { $0 + $1.count }
        current?.lostPackets += lostPackets
        current?.lastArrival = arrival
        if pending.count >= 16_384 || arrival.timeIntervalSince(lastFlush) >= flushInterval {
            try flush(at: arrival)
        }
    }

    /// Ends the segment if no audio has arrived for `idleGap`. Call periodically.
    public func closeIfIdle(now: Date = .now) {
        guard let segment = current, now.timeIntervalSince(segment.lastArrival) > idleGap else { return }
        close(.idle)
    }

    public func flush(at now: Date = .now) throws {
        lastFlush = now
        guard let handle, !pending.isEmpty, let segment = current else { return }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        onUpdate?(segment)
    }

    public func close(_ reason: CloseReason) {
        guard let segment = current else { return }
        try? flush()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        current = nil
        onClose?(segment, reason)
    }

    public func url(for segment: Segment) -> URL { directory.appendingPathComponent(segment.file) }

    private func open(deviceID: String, sampleRate: Int, start: Date, arrival: Date) throws {
        let id = UUID()
        let day = AudioRecorder.dayFormatter.string(from: start)
        let name = "\(AudioRecorder.timeFormatter.string(from: start))-\(id.uuidString.prefix(8)).aac"
        let folder = directory.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AudioRecorder.excludeFromBackup(directory)
        let url = folder.appendingPathComponent(name)
        // Default protection (until first unlock): the file stays writable while the phone is locked.
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        let segment = Segment(id: id, deviceID: deviceID, file: "\(day)/\(name)", start: start, lastArrival: arrival, sampleRate: sampleRate)
        current = segment
        lastFlush = arrival
        onOpen?(segment)
    }

    /// Audio is big and only means something on this device: keep it out of iCloud backups.
    public static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return f
    }()
}
