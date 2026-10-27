import CoreML
import FluidAudio
import Foundation

/// Finds speech with Silero VAD (FluidAudio). It's light enough for the CPU (well over 1000x real time),
/// which keeps it usable in the background, where the Neural Engine isn't.
public actor SpeechScanner {
    private var vad: VadManager?
    private let segmentation: VadSegmentationConfig

    public init() {
        segmentation = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.6, maxSpeechDuration: 30, speechPadding: 0.2)
    }

    /// Loads (downloading once, about 2 MB) the model.
    public func prepare() async throws {
        guard vad == nil else { return }
        do {
            vad = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
        } catch {
            if error.isCancellation || Task.isCancelled { throw CancellationError() }
            throw PipelineError.modelUnavailable("Couldn't load the voice detector: \(error.localizedDescription)")
        }
    }

    /// Speech regions in 16 kHz mono samples, in seconds from the start.
    public func speech(in samples: [Float]) async throws -> [TimeSpan] {
        try await prepare()
        guard let vad, samples.count >= VadManager.chunkSize else { return [] }
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        return segments.map { TimeSpan(start: $0.startTime, end: $0.endTime) }
    }

    public func unload() {
        vad = nil
    }
}

/// Groups speech into conversations: a silence longer than `gap` ends one, and a "conversation" with
/// less than `minimumSpeech` of talking is dropped as noise (a cough, a door). The Bee only records when
/// asked to, so the bar is low: a short note to self is worth keeping.
public struct ConversationPlanner: Sendable {
    public struct Plan: Hashable, Sendable {
        public var span: DateInterval
        public var regions: [DateInterval]
        public var speech: TimeInterval { regions.reduce(0) { $0 + $1.duration } }
    }

    public var gap: TimeInterval
    public var minimumSpeech: TimeInterval

    public init(gap: TimeInterval = 120, minimumSpeech: TimeInterval = 2) {
        self.gap = gap
        self.minimumSpeech = minimumSpeech
    }

    public struct Result: Hashable, Sendable {
        /// Conversations followed by at least `gap` of silence, with enough speech to keep.
        public var closed: [Plan]
        /// The last one, if it could still continue.
        public var open: Plan?
        /// Closed, but with too little speech to keep.
        public var dropped: [Plan] = []
        /// Everything up to here has been decided (kept or dropped). Plan from here next time.
        public var through: Date?
    }

    /// `regions` are absolute speech regions in any order. `horizon` is how far audio has been checked
    /// for speech: a conversation is only closed once `gap` of silence after it has been seen (or the
    /// capture stopped, in which case pass `.distantFuture`).
    public func plan(_ regions: [DateInterval], horizon: Date) -> Result {
        var groups: [Plan] = []
        for region in regions.sorted(by: { $0.start < $1.start }) {
            if var last = groups.last, region.start.timeIntervalSince(last.span.end) <= gap {
                last.regions.append(region)
                last.span = DateInterval(start: last.span.start, end: max(last.span.end, region.end))
                groups[groups.count - 1] = last
            } else {
                groups.append(Plan(span: region, regions: [region]))
            }
        }
        var open: Plan?
        if let last = groups.last, last.span.end.addingTimeInterval(gap) > horizon {
            open = last
            groups.removeLast()
        }
        return Result(
            closed: groups.filter { $0.speech >= minimumSpeech },
            open: open,
            dropped: groups.filter { $0.speech < minimumSpeech },
            through: groups.last?.span.end
        )
    }
}

/// Cuts a stretch out of a recording, to delete one conversation's audio. A recording is a run of
/// fixed-length frames, so time maps to frames. What's left on either side is kept only if it holds
/// speech (another conversation's, or one not planned yet); without any, it was silence.
public enum AudioCut {
    public struct Piece: Hashable, Sendable {
        public var frames: Range<Int>
        /// Seconds from the recording's start.
        public var offset: TimeInterval
        /// Speech in the piece, in seconds from the piece's start.
        public var speech: [TimeSpan]
    }

    /// The pieces to keep after removing `cut` (seconds from the recording's start), in order. Empty: delete
    /// the whole recording. A recording `cut` doesn't touch comes back whole.
    public static func remove(_ cut: TimeSpan, frames: Int, frameDuration: TimeInterval, speech: [TimeSpan]) -> [Piece] {
        let first = min(max(0, Int((cut.start / frameDuration).rounded(.down))), frames)
        let last = min(max(0, Int((cut.end / frameDuration).rounded(.up))), frames)
        guard first < last else { return [Piece(frames: 0..<frames, offset: 0, speech: speech)] }
        return [0..<first, last..<frames].compactMap { range in
            guard !range.isEmpty else { return nil }
            let span = TimeSpan(start: Double(range.lowerBound) * frameDuration, end: Double(range.upperBound) * frameDuration)
            let kept = speech.compactMap { region -> TimeSpan? in
                let clipped = TimeSpan(start: max(region.start, span.start), end: min(region.end, span.end))
                return clipped.duration > 0 ? clipped.shifted(by: -span.start) : nil
            }
            return kept.isEmpty ? nil : Piece(frames: range, offset: span.start, speech: kept)
        }
    }
}

/// Speech regions cut out of their recordings and joined with short pauses, so the models don't spend
/// time on silence. Keeps the map back to real time.
public struct SplicedAudio: Sendable {
    public struct Piece: Hashable, Sendable {
        /// Where the piece starts in `samples`, in seconds.
        public var offset: TimeInterval
        /// Where it came from, in seconds from the conversation's start.
        public var source: TimeInterval
        public var length: TimeInterval
    }

    public static let pause: TimeInterval = 0.3

    public private(set) var samples: [Float] = []
    public private(set) var pieces: [Piece] = []

    public init() {}

    public var duration: TimeInterval { Double(samples.count) / Double(AudioLoader.sampleRate) }

    public mutating func append(_ piece: [Float], from source: TimeInterval) {
        guard !piece.isEmpty else { return }
        if !samples.isEmpty { samples += [Float](repeating: 0, count: Int(Self.pause * Double(AudioLoader.sampleRate))) }
        pieces.append(Piece(offset: duration, source: source, length: Double(piece.count) / Double(AudioLoader.sampleRate)))
        samples += piece
    }

    /// Real time (seconds from the conversation's start) for a time in `samples`.
    public func sourceTime(_ t: TimeInterval) -> TimeInterval {
        guard let piece = pieces.last(where: { $0.offset <= t }) ?? pieces.first else { return t }
        return piece.source + min(max(0, t - piece.offset), piece.length)
    }

    public func source(_ span: TimeSpan) -> TimeSpan {
        let start = sourceTime(span.start)
        return TimeSpan(start: start, end: max(start, sourceTime(span.end)))
    }

    /// Root mean square of `samples` over `span`.
    public func loudness(_ span: TimeSpan) -> Float {
        let rate = Double(AudioLoader.sampleRate)
        let lower = max(0, Int(span.start * rate)), upper = min(samples.count, Int(span.end * rate))
        guard upper > lower else { return 0 }
        var sum: Float = 0
        for i in lower..<upper { sum += samples[i] * samples[i] }
        return (sum / Float(upper - lower)).squareRoot()
    }
}
