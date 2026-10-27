import Foundation
import FoundationModels

/// What one conversation was about. Extracted per chunk, then merged.
@Generable(description: "Notes on a conversation picked up by a microphone the user (\"Me\") wears")
public struct ConversationNotes: Sendable, Codable, Hashable {
    @Guide(description: "A short title, 3 to 7 words, naming what the conversation was about")
    public var title: String
    @Guide(description: "Two to four plain, factual sentences on what was discussed and decided")
    public var summary: String
    @Guide(description: "Tasks Me agreed to do, or that someone asked Me to do. Empty if there are none. Don't invent any.", .maximumCount(5))
    public var actionItems: [ActionItemNote]
    @Guide(description: "Up to 4 topics, one or two words each", .maximumCount(4))
    public var topics: [String]
    @Guide(description: "True if this sounds like a TV show, podcast, video or song playing, not people talking with Me")
    public var soundsLikeMedia: Bool

    public init(title: String, summary: String, actionItems: [ActionItemNote], topics: [String], soundsLikeMedia: Bool) {
        self.title = title
        self.summary = summary
        self.actionItems = actionItems
        self.topics = topics
        self.soundsLikeMedia = soundsLikeMedia
    }
}

@Generable
public struct ActionItemNote: Sendable, Codable, Hashable {
    @Guide(description: "The task as a short imperative, for example \"Send Sam the slides\"")
    public var task: String
    @Guide(description: "Who is going to do it")
    public var owner: TaskOwner
    @Guide(description: "When it's due, in the speaker's words, or empty if nobody said")
    public var due: String
    @Guide(description: "The words in the transcript this task comes from, copied exactly")
    public var quote: String

    public init(task: String, owner: TaskOwner, due: String, quote: String) {
        self.task = task
        self.owner = owner
        self.due = due
        self.quote = quote
    }
}

@Generable
public enum TaskOwner: String, Sendable, Codable, Hashable {
    case me
    case someoneElse
    case unclear
}

/// The evening digest. Commitments first: reviewers found those the useful part.
@Generable(description: "A digest of one day of the user's (\"Me\") conversations")
public struct DayDigest: Sendable, Codable, Hashable {
    @Guide(description: "One sentence on the day, addressed to Me as \"you\"")
    public var headline: String
    @Guide(description: "Commitments Me made or was given today, most important first. Empty if none.", .maximumCount(7))
    public var commitments: [String]
    @Guide(description: "Up to 5 notable things from the day's conversations", .maximumCount(5))
    public var highlights: [String]

    public init(headline: String, commitments: [String], highlights: [String]) {
        self.headline = headline
        self.commitments = commitments
        self.highlights = highlights
    }
}

/// Apple's on-device model (Foundation Models). Its context is about 4K tokens, so a transcript goes in
/// as chunks, each gets its own notes in a fresh session, and the notes are merged, never the raw text.
/// Never uses Private Cloud Compute: everything stays on the phone.
public struct NoteTaker: Sendable {
    public enum Availability: Equatable, Sendable {
        case available
        case deviceNotEligible
        case appleIntelligenceOff
        case notReady
        case unavailable

        public var explanation: String? {
            switch self {
            case .available: nil
            case .deviceNotEligible: "This iPhone can't run Apple Intelligence, so conversations won't get summaries."
            case .appleIntelligenceOff: "Turn on Apple Intelligence in Settings to get summaries and to-dos."
            case .notReady: "Apple Intelligence is still downloading its model. Summaries will start once it's ready."
            case .unavailable: "Apple Intelligence isn't available right now."
            }
        }
    }

    private static let instructions = """
        You write notes on conversations recorded by a small microphone the user wears. In transcripts, "Me" \
        is the user. Other speakers are named when known, otherwise "Speaker 2" and so on. The transcript \
        comes from speech recognition and can have mistakes. Be brief and factual. Use only what was said; \
        never invent tasks, names or facts. A task only counts if Me agreed to do it or was asked to do it. \
        Me pressed a button to bookmark lines marked [bookmarked]: make sure the notes cover them. \
        In what you write, call Me "you" (for example "You agreed to send the slides"), never "Me".
        """

    private var model: SystemLanguageModel { SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations) }

    public init() {}

    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: .deviceNotEligible
            case .appleIntelligenceNotEnabled: .appleIntelligenceOff
            case .modelNotReady: .notReady
            @unknown default: .unavailable
            }
        @unknown default: .unavailable
        }
    }

    /// For the about screen: which model is serving, and its context size.
    public static var modelDescription: String {
        let model = SystemLanguageModel.default
        return "\(model.variant) · \(model.contextSize) tokens"
    }

    /// Notes for one conversation. `names` maps speaker labels to how they're shown ("Me", "Sam").
    public func notes(for utterances: [Utterance], names: [String: String]) async throws -> ConversationNotes {
        let lines = utterances.map { "\(names[$0.speaker] ?? $0.speaker): \($0.text)" }
        let chunks = try await Self.chunk(lines, budget: chunkBudget)
        var parts: [ConversationNotes] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let context = chunks.count > 1 ? "This is part \(i + 1) of \(chunks.count) of one conversation.\n\n" : ""
            parts.append(try await extract(chunk, context: context))
        }
        return try await merge(parts)
    }

    public func digest(_ day: [(start: Date, notes: ConversationNotes)]) async throws -> DayDigest {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let entries = day.sorted { $0.start < $1.start }.map { entry in
            var text = "\(entry.start.formatted(time)) \(entry.notes.title): \(entry.notes.summary)"
            for item in entry.notes.actionItems where item.owner != .someoneElse {
                text += "\n  task: \(item.task)\(item.due.isEmpty ? "" : " (\(item.due))")"
            }
            return text
        }
        let text = entries.joined(separator: "\n")
        let prompt = "Write the digest for this day. Conversations:\n\n\(text)"
        return try await respond(prompt, generating: DayDigest.self)
    }

    // MARK: map and reduce

    /// Room for transcript in one request: the context minus instructions, schema and the answer.
    private var chunkBudget: Int { max(800, SystemLanguageModel.default.contextSize - 1800) }

    private func extract(_ transcript: String, context: String) async throws -> ConversationNotes {
        do {
            return try await respond("\(context)Transcript:\n\n\(transcript)", generating: ConversationNotes.self)
        } catch let error as ContextTooLong {
            // The estimate was off. Halve and merge.
            let lines = transcript.split(separator: "\n").map(String.init)
            guard lines.count > 1 else { throw error.underlying }
            let half = lines.count / 2
            let a = try await extract(lines[..<half].joined(separator: "\n"), context: context)
            let b = try await extract(lines[half...].joined(separator: "\n"), context: context)
            return try await merge([a, b])
        }
    }

    /// Merges the parts' notes in a fresh session, a few at a time if there are many.
    private func merge(_ parts: [ConversationNotes]) async throws -> ConversationNotes {
        guard parts.count > 1 else {
            if let only = parts.first { return only }
            throw PipelineError.notesUnavailable("Nothing to summarize.")
        }
        if parts.count > 6 {
            var merged: [ConversationNotes] = []
            for start in stride(from: 0, to: parts.count, by: 6) {
                merged.append(try await merge(Array(parts[start..<min(start + 6, parts.count)])))
            }
            return try await merge(merged)
        }
        let listed = parts.enumerated().map { i, part in
            var text = "Part \(i + 1): \(part.title). \(part.summary)"
            for item in part.actionItems {
                text += "\n  task (\(item.owner.rawValue)): \(item.task)\(item.due.isEmpty ? "" : ", due \(item.due)") — \"\(item.quote)\""
            }
            if !part.topics.isEmpty { text += "\n  topics: \(part.topics.joined(separator: ", "))" }
            return text
        }.joined(separator: "\n")
        let prompt = """
            These are notes on consecutive parts of one conversation. Combine them into notes on the whole \
            conversation. Merge duplicate tasks and keep their quotes.

            \(listed)
            """
        var notes = try await respond(prompt, generating: ConversationNotes.self)
        notes.soundsLikeMedia = notes.soundsLikeMedia || parts.allSatisfy(\.soundsLikeMedia)
        return notes
    }

    private func respond<T: Generable>(_ prompt: String, generating type: T.Type) async throws -> T {
        let session = LanguageModelSession(model: model, instructions: Instructions(Self.instructions))
        do {
            return try await session.respond(to: prompt, generating: type, options: GenerationOptions(temperature: 0.2)).content
        } catch let error as LanguageModelError {
            switch error {
            case let .rateLimited(info): throw PipelineError.rateLimited(info.resetDate)
            case .guardrailViolation: throw PipelineError.declined("content guardrails")
            case .refusal: throw PipelineError.declined("it refused")
            case .contextSizeExceeded: throw ContextTooLong(underlying: error)
            case .unsupportedLanguageOrLocale: throw PipelineError.notesUnavailable("Apple Intelligence doesn't support this conversation's language yet.")
            default: throw error
            }
        }
    }

    private struct ContextTooLong: Error {
        var underlying: Error
    }

    /// Packs lines into chunks of about `budget` tokens, cutting only between lines (speaker turns).
    static func chunk(_ lines: [String], budget: Int) async throws -> [String] {
        // Close enough for English; each chunk is checked with the real tokenizer after.
        func estimate(_ text: String) -> Int { text.utf8.count / 3 + 1 }
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            let cost = estimate(line)
            if size + cost > budget, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += cost
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }
}
