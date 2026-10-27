import CoreML
import FluidAudio
import Foundation

/// Who spoke when: pyannote community-1 (FluidAudio's offline pipeline), once per closed conversation.
/// Body-worn audio is hard for diarization, so lean on the split that matters most, "Me" versus others.
public actor SpeakerSeparator {
    private var manager: OfflineDiarizerManager?
    private var placement: ComputePlacement?

    public init() {}

    public func prepare(_ placement: ComputePlacement) async throws {
        if manager != nil, self.placement == placement { return }
        let manager = OfflineDiarizerManager(config: .default)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = placement == .background ? .cpuOnly : .all
        do {
            try await manager.prepareModels(configuration: configuration)
        } catch {
            if error.isCancellation || Task.isCancelled { throw CancellationError() }
            throw PipelineError.modelUnavailable("Couldn't load the speaker models: \(error.localizedDescription)")
        }
        self.manager = manager
        self.placement = placement
    }

    /// Turns in 16 kHz mono samples. Exclusive: no two turns overlap.
    public func turns(in samples: [Float]) async throws -> [SpeakerTurn] {
        if manager == nil { try await prepare(.foreground) }
        guard let loaded = manager, samples.count >= AudioLoader.sampleRate else { return [] }
        // FluidAudio's diarizer is a plain class that runs on the generic executor. The processor sends
        // one conversation at a time, so it's never used from two places at once.
        nonisolated(unsafe) let manager = loaded
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, span: TimeSpan(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)), embedding: $0.embedding)
        }
    }

    public func unload() {
        manager = nil
        placement = nil
    }
}

/// A known voice: the wearer ("Me") or someone they've named.
public struct Voiceprint: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var isMe: Bool
    public var embedding: [Float]
    /// How many conversations went into the running mean.
    public var samples: Int

    public init(id: UUID = UUID(), name: String, isMe: Bool, embedding: [Float], samples: Int = 1) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.embedding = Speakers.normalized(embedding)
        self.samples = samples
    }

    /// Folds in another conversation's centroid for this person.
    public mutating func learn(_ centroid: [Float]) {
        guard centroid.count == embedding.count else { return }
        let n = Float(samples)
        embedding = Speakers.normalized(zip(embedding, Speakers.normalized(centroid)).map { ($0 * n + $1) / (n + 1) })
        samples += 1
    }
}

public enum Speakers {
    /// Cosine similarity above which a speaker is taken to be a known voice. A starting point to tune.
    public static let matchThreshold: Float = 0.65

    /// A speaker found in one conversation: its centroid, and who it matched (if anyone).
    public struct Cluster: Hashable, Sendable, Codable {
        public var label: String
        public var centroid: [Float]
        public var seconds: TimeInterval
        public var voiceprint: UUID?
        public var similarity: Float?

        public init(label: String, centroid: [Float], seconds: TimeInterval, voiceprint: UUID? = nil, similarity: Float? = nil) {
            self.label = label
            self.centroid = centroid
            self.seconds = seconds
            self.voiceprint = voiceprint
            self.similarity = similarity
        }
    }

    /// One centroid per speaker, weighted by how long each turn is.
    public static func clusters(_ turns: [SpeakerTurn]) -> [Cluster] {
        var sums: [String: [Float]] = [:]
        var seconds: [String: TimeInterval] = [:]
        for turn in turns where !turn.embedding.isEmpty {
            let weight = Float(turn.span.duration)
            let vector = normalized(turn.embedding).map { $0 * weight }
            sums[turn.speaker] = sums[turn.speaker].map { zip($0, vector).map(+) } ?? vector
            seconds[turn.speaker, default: 0] += turn.span.duration
        }
        return sums.map { Cluster(label: $0.key, centroid: normalized($0.value), seconds: seconds[$0.key] ?? 0) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Matches clusters to voiceprints, best pairs first, each voiceprint used at most once.
    public static func match(_ clusters: [Cluster], to voiceprints: [Voiceprint], threshold: Float = matchThreshold) -> [Cluster] {
        var pairs: [(cluster: Int, print: Int, score: Float)] = []
        for (c, cluster) in clusters.enumerated() {
            for (p, print) in voiceprints.enumerated() {
                let score = cosine(cluster.centroid, print.embedding)
                if score >= threshold { pairs.append((c, p, score)) }
            }
        }
        var out = clusters
        var usedClusters = Set<Int>(), usedPrints = Set<Int>()
        for pair in pairs.sorted(by: { $0.score > $1.score }) where !usedClusters.contains(pair.cluster) && !usedPrints.contains(pair.print) {
            out[pair.cluster].voiceprint = voiceprints[pair.print].id
            out[pair.cluster].similarity = pair.score
            usedClusters.insert(pair.cluster)
            usedPrints.insert(pair.print)
        }
        return out
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Gives every word one speaker (the turn covering most of it, else the nearest) and joins runs of
    /// words into utterances, breaking on a speaker change or a pause longer than `maxPause`.
    public static func utterances(words: [Word], turns: [SpeakerTurn], maxPause: TimeInterval = 1.5, maxLength: TimeInterval = 40) -> [Utterance] {
        let sortedTurns = turns.sorted { $0.span.start < $1.span.start }
        var out: [Utterance] = []
        var previousSpeaker = sortedTurns.first?.speaker ?? "S1"
        for word in words.sorted(by: { $0.span.start < $1.span.start }) {
            let speaker = speaker(for: word.span, in: sortedTurns) ?? previousSpeaker
            previousSpeaker = speaker
            if var last = out.last, last.speaker == speaker, word.span.start - last.span.end <= maxPause,
               word.span.end - last.span.start <= maxLength || !endsSentence(last.text) {
                last.text += joiner(last.text, word.text) + word.text
                last.span.end = max(last.span.end, word.span.end)
                out[out.count - 1] = last
            } else {
                out.append(Utterance(speaker: speaker, span: word.span, text: word.text))
            }
        }
        return out
    }

    private static func speaker(for span: TimeSpan, in turns: [SpeakerTurn]) -> String? {
        var best: (String, TimeInterval)?
        for turn in turns {
            if turn.span.start > span.end + 1 { break }
            let overlap = turn.span.overlap(with: span)
            if overlap > (best?.1 ?? 0) { best = (turn.speaker, overlap) }
        }
        if let best { return best.0 }
        // Between turns: the nearest one within a second.
        let nearest = turns.min { distance($0.span, span) < distance($1.span, span) }
        return nearest.flatMap { distance($0.span, span) <= 1 ? $0.speaker : nil }
    }

    private static func distance(_ a: TimeSpan, _ b: TimeSpan) -> TimeInterval {
        max(0, max(a.start - b.end, b.start - a.end))
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!".contains(last)
    }

    /// No space before punctuation that the recognizer split off.
    private static func joiner(_ text: String, _ next: String) -> String {
        guard let first = next.first else { return "" }
        return ",.?!;:%)".contains(first) || text.isEmpty ? "" : " "
    }
}
