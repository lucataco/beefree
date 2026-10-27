import BeeKit
import BeePipeline
import BeeProtocol
import Foundation
import SwiftData

/// One archived ADTS file: a contiguous run of audio from the Bee.
@Model
final class AudioSegment {
    @Attribute(.unique) var id: UUID
    var deviceID: String
    /// Relative to `Library.recordings`.
    var file: String
    var start: Date
    var lastArrival: Date
    var frames: Int
    var bytes: Int
    var sampleRate: Int
    var lostPackets: Int
    /// Still being written.
    var isOpen: Bool
    var closeReason: String?
    /// Voice detection has run.
    var scanned = false
    var speechSeconds: Double = 0
    /// Speech regions as `[TimeSpan]` JSON, seconds from `start`.
    var regionsData: Data?
    /// The file was deleted (silent, or past retention); the row stays for the capture history.
    var audioDeleted = false

    init(_ segment: AudioRecorder.Segment) {
        id = segment.id
        deviceID = segment.deviceID
        file = segment.file
        start = segment.start
        lastArrival = segment.lastArrival
        frames = segment.frames
        bytes = segment.bytes
        sampleRate = segment.sampleRate
        lostPackets = segment.lostPackets
        isOpen = true
    }

    /// What's left after a conversation was cut from the middle of `segment`, saved as `file`. The caller
    /// sets its start, frames and speech.
    init(remainderOf segment: AudioSegment, file: String) {
        id = UUID()
        deviceID = segment.deviceID
        self.file = file
        start = segment.start
        lastArrival = segment.lastArrival
        frames = 0
        bytes = 0
        sampleRate = segment.sampleRate
        lostPackets = 0
        isOpen = false
        closeReason = segment.closeReason
        scanned = segment.scanned
    }

    func update(_ segment: AudioRecorder.Segment) {
        lastArrival = segment.lastArrival
        frames = segment.frames
        bytes = segment.bytes
        lostPackets = segment.lostPackets
    }

    var duration: TimeInterval { Double(frames * ADTSHeader.samplesPerFrame) / Double(max(sampleRate, 1)) }
    var end: Date { start.addingTimeInterval(duration) }
    var url: URL { Library.recordings.appendingPathComponent(file) }

    var regions: [TimeSpan] {
        get { regionsData.flatMap { try? JSONDecoder().decode([TimeSpan].self, from: $0) } ?? [] }
        set { regionsData = try? JSONEncoder().encode(newValue) }
    }
}

/// A conversation: speech with no silence longer than the gap setting.
@Model
final class Conversation {
    enum Stage: String {
        /// Found, waiting for transcription.
        case pending
        case transcribed
        /// Has notes (or notes aren't possible; see `notesError`).
        case summarized
        case failed
    }

    @Attribute(.unique) var id: UUID
    var start: Date
    var end: Date
    var speechSeconds: Double
    /// `[DateInterval]` JSON: where the speech is.
    var regionsData: Data
    var stageRaw: String
    var engine: String?
    var title: String?
    var summary: String?
    var topics: [String] = []
    var soundsLikeMedia = false
    var notesError: String?
    var failure: String?
    var attempts = 0
    /// `[SpeakerInfo]` JSON.
    var speakersData: Data?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptLine.conversation) var lines: [TranscriptLine] = []
    @Relationship(deleteRule: .cascade, inverse: \TodoItem.conversation) var todos: [TodoItem] = []

    init(start: Date, end: Date, speechSeconds: Double, regions: [DateInterval]) {
        id = UUID()
        self.start = start
        self.end = end
        self.speechSeconds = speechSeconds
        regionsData = (try? JSONEncoder().encode(regions)) ?? Data()
        stageRaw = Stage.pending.rawValue
    }

    var stage: Stage {
        get { Stage(rawValue: stageRaw) ?? .pending }
        set { stageRaw = newValue.rawValue }
    }

    var regions: [DateInterval] { (try? JSONDecoder().decode([DateInterval].self, from: regionsData)) ?? [] }

    var speakers: [SpeakerInfo] {
        get { speakersData.flatMap { try? JSONDecoder().decode([SpeakerInfo].self, from: $0) } ?? [] }
        set { speakersData = try? JSONEncoder().encode(newValue) }
    }

    var sortedLines: [TranscriptLine] { lines.sorted { $0.index < $1.index } }

    /// How each speaker label is shown: "Me", a name, or "Speaker 2".
    var speakerNames: [String: String] {
        Dictionary(speakers.map { ($0.label, $0.displayName) }, uniquingKeysWith: { a, _ in a })
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return stage == .pending ? "Waiting to be transcribed" : "Conversation"
    }
}

/// A speaker in one conversation.
struct SpeakerInfo: Codable, Hashable, Identifiable {
    var label: String
    /// 1-based, by talk time: "Speaker 2" and so on.
    var number: Int
    var name: String?
    var isMe: Bool
    /// The loudest voice, taken to be the wearer until they say otherwise.
    var guessedMe = false
    var profile: UUID?
    var centroid: [Float]
    var seconds: Double
    var loudness: Float

    var id: String { label }

    var displayName: String {
        if isMe { return "Me" }
        if let name { return name }
        return "Speaker \(number)"
    }
}

@Model
final class TranscriptLine {
    var conversation: Conversation?
    var index: Int
    var start: Date
    var end: Date
    var speaker: String
    var text: String

    init(index: Int, start: Date, end: Date, speaker: String, text: String) {
        self.index = index
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

@Model
final class TodoItem {
    enum State: String {
        case inbox, done, dismissed
    }

    var conversation: Conversation?
    var task: String
    var ownerRaw: String
    var due: String
    var quote: String
    /// Where the quote is, for jumping to the transcript and the audio.
    var quoteTime: Date?
    var created: Date
    var stateRaw: String

    init(_ note: ActionItemNote, quoteTime: Date?, created: Date) {
        task = note.task
        ownerRaw = note.owner.rawValue
        due = note.due
        quote = note.quote
        self.quoteTime = quoteTime
        self.created = created
        stateRaw = State.inbox.rawValue
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .inbox }
        set { stateRaw = newValue.rawValue }
    }

    var owner: TaskOwner { TaskOwner(rawValue: ownerRaw) ?? .unclear }
}

/// A voice the app knows: the wearer, or someone they named.
@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var isMe: Bool
    var embedding: [Float]
    var samples: Int

    init(_ print: Voiceprint) {
        id = print.id
        name = print.name
        isMe = print.isMe
        embedding = print.embedding
        samples = print.samples
    }

    var voiceprint: Voiceprint {
        Voiceprint(id: id, name: name, isMe: isMe, embedding: embedding, samples: samples)
    }
}

/// The digest of one day.
@Model
final class DayNote {
    @Attribute(.unique) var day: Date
    var headline: String
    var commitments: [String]
    var highlights: [String]
    var conversationCount: Int
    var generated: Date

    init(day: Date, digest: DayDigest, conversationCount: Int) {
        self.day = day
        headline = digest.headline
        commitments = digest.commitments
        highlights = digest.highlights
        self.conversationCount = conversationCount
        generated = .now
    }

    func update(_ digest: DayDigest, conversationCount: Int) {
        headline = digest.headline
        commitments = digest.commitments
        highlights = digest.highlights
        self.conversationCount = conversationCount
        generated = .now
    }
}

/// Where recordings live, and the models SwiftData stores.
enum Library {
    static let models: [any PersistentModel.Type] = [
        LogEntry.self, AudioSegment.self, Conversation.self, TranscriptLine.self, TodoItem.self, SpeakerProfile.self, DayNote.self,
    ]

    /// In the app's own container (not the App Group: the widget never needs audio), out of backups.
    static let recordings: URL = {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? AudioRecorder.excludeFromBackup(url)
        return url
    }()

    static func bytesOnDisk() -> Int64 {
        guard let files = FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
