import BeeKit
import BeePipeline
import BeeProtocol
import Foundation
import Observation
import SwiftData
import UIKit

/// Everything after capture, in stages that each checkpoint to SwiftData, so a run can stop anywhere
/// (the app backgrounds, a background task expires) and the next one picks up where it left off:
///
/// 1. find speech in each closed segment (Silero, CPU);
/// 2. group speech into conversations;
/// 3. transcribe (Parakeet or Apple Speech) and separate speakers (pyannote), one conversation at a time;
/// 4. notes and to-dos (Foundation Models), then each day's digest.
///
/// In the foreground the models use the Neural Engine. In the background they're CPU only: iOS 27 keeps
/// the Neural Engine from background apps without the Background Inference entitlement.
@Observable
final class Processor {
    struct Progress: Equatable {
        var step: String
        var done: Int
        var total: Int

        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// Who started the run. Foreground runs stop when the app leaves the screen; background tasks don't.
    enum Owner {
        case foreground
        /// "Process now", continuing as a `BGContinuedProcessingTask`.
        case continued
        /// The overnight `BGProcessingTask` (on external power).
        case nightly

        var label: String {
            switch self {
            case .foreground: "in the app"
            case .continued: "Process Now"
            case .nightly: "overnight"
            }
        }
    }

    struct Backlog: Equatable {
        var segments = 0
        var conversations = 0
        var notes = 0

        var isEmpty: Bool { segments == 0 && conversations == 0 && notes == 0 }
        var units: Int { segments + conversations + notes }
    }

    /// What a run did, so one that makes nothing says why.
    struct Tally {
        var checked = 0
        var silent = 0
        var found = 0
        var tooShort: TimeInterval = 0
        var transcribed = 0
        var summarized = 0

        var summary: String {
            var parts: [String] = []
            if found > 0 { parts.append(Self.count(found, "new conversation")) }
            if silent > 0 { parts.append(Self.count(silent, "recording") + " had no speech") }
            if tooShort > 0 { parts.append("\(tooShort.formatted(.number.precision(.fractionLength(1)))) s of speech too short to keep") }
            if transcribed > 0 { parts.append("\(transcribed) transcribed") }
            if summarized > 0 { parts.append("\(summarized) summarized") }
            return parts.isEmpty ? "nothing new" : parts.joined(separator: ", ")
        }

        private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    }

    private(set) var progress: Progress?
    private(set) var lastError: String?
    private(set) var lastFinished: Date?
    /// The last run's `Tally.summary`.
    private(set) var lastOutcome: String?
    /// While Parakeet downloads (about 480 MB, once).
    private(set) var downloading: Double?
    private(set) var parakeetReady = ParakeetEngine.isDownloaded

    var engine: EngineChoice {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "engine")
            asr = nil
        }
    }

    /// Silence that ends a conversation.
    var gapMinutes: Int {
        didSet { UserDefaults.standard.set(gapMinutes, forKey: "gapMinutes") }
    }

    /// Delete segments with no speech at all once they've been checked.
    var deleteSilence: Bool {
        didSet { UserDefaults.standard.set(deleteSilence, forKey: "deleteSilence") }
    }

    var isRunning: Bool { progress != nil }
    private(set) var owner: Owner = .foreground

    /// The segment the recorder is writing, if any. Set by the store.
    @ObservationIgnored var openSegmentID: () -> UUID? = { nil }
    @ObservationIgnored var onLog: ((String) -> Void)?
    /// A day's digest was written (or rewritten).
    @ObservationIgnored var onDigest: ((DayNote) -> Void)?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let scanner = SpeechScanner()
    @ObservationIgnored private let separator = SpeakerSeparator()
    @ObservationIgnored private var asr: (any SpeechEngine)?
    @ObservationIgnored private var run: Task<Bool, Never>?
    @ObservationIgnored private var reporters: [(Progress) -> Void] = []
    @ObservationIgnored private var tally = Tally()

    init(context: ModelContext) {
        self.context = context
        let defaults = UserDefaults.standard
        engine = defaults.string(forKey: "engine").flatMap(EngineChoice.init(rawValue:)) ?? .parakeet
        gapMinutes = defaults.object(forKey: "gapMinutes") as? Int ?? 2
        deleteSilence = defaults.object(forKey: "deleteSilence") as? Bool ?? true
    }

    // MARK: - running

    /// Runs every stage that has work. Joins a run already in progress. Returns true if it got through
    /// everything, false if it was cancelled or stopped on an error.
    @discardableResult
    func process(as owner: Owner = .foreground, report: ((Progress) -> Void)? = nil) async -> Bool {
        if let run {
            // A background task joining a foreground run takes it over, so leaving the app won't stop it.
            if owner != .foreground { self.owner = owner }
            if let report { reporters.append(report) }
            return await run.value
        }
        self.owner = owner
        reporters = report.map { [$0] } ?? []
        let task = Task { await self.work() }
        run = task
        let finished = await task.value
        run = nil
        return finished
    }

    func cancel() {
        run?.cancel()
    }

    /// The background task behind a run ended while the app is on screen: carry on as an in-app run.
    func keepRunningInApp() {
        guard run != nil else { return }
        owner = .foreground
        reporters = []
    }

    var backlog: Backlog {
        let pending = Conversation.Stage.pending.rawValue, transcribed = Conversation.Stage.transcribed.rawValue
        let open = openSegmentID()
        let segments = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { !$0.scanned && !$0.audioDeleted }))) ?? []
        return Backlog(
            segments: segments.filter { $0.id != open && !$0.isOpen }.count,
            conversations: (try? context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.stageRaw == pending }))) ?? 0,
            notes: NoteTaker.availability == .available
                ? (try? context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.stageRaw == transcribed }))) ?? 0 : 0
        )
    }

    /// Downloads Parakeet ahead of time (in the foreground, ideally on Wi-Fi).
    func downloadParakeet() async {
        guard downloading == nil else { return }
        downloading = 0
        defer { downloading = nil }
        do {
            try await ParakeetEngine.download { fraction in
                Task { @MainActor in self.downloading = fraction }
            }
            parakeetReady = ParakeetEngine.isDownloaded
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var placement: ComputePlacement {
        UIApplication.shared.applicationState == .background ? .background : .foreground
    }

    private func work() async -> Bool {
        lastError = nil
        tally = Tally()
        var done = 0
        var total = backlog.units
        let started = Date.now
        let placementName = placement == .foreground ? "foreground" : "background, CPU only"
        onLog?("Processing started (\(owner.label), \(placementName)): \(Self.describe(backlog))")
        func step(_ name: String) {
            let progress = Progress(step: name, done: done, total: max(total, done + 1))
            self.progress = progress
            for report in reporters { report(progress) }
        }
        defer {
            progress = nil
            Task { await self.unloadModels() }
        }
        do {
            recoverInterrupted()
            for segment in segmentsToScan() {
                try Task.checkCancellation()
                step("Finding speech")
                try await scan(segment)
                tally.checked += 1
                if segment.speechSeconds == 0 { tally.silent += 1 }
                done += 1
            }
            planConversations()
            total = done + backlog.units

            for conversation in conversations(in: .pending) {
                try Task.checkCancellation()
                step("Transcribing")
                do {
                    try await transcribe(conversation)
                    tally.transcribed += 1
                } catch let error as PipelineError {
                    if case .modelUnavailable = error { throw error }
                    fail(conversation, error)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    fail(conversation, error)
                }
                done += 1
            }
            await unloadModels() // free the speech models before the language model runs

            if NoteTaker.availability != .available, !conversations(in: .transcribed).isEmpty {
                onLog?("Notes skipped: \(NoteTaker.availability.explanation ?? "Apple Intelligence isn't available.")")
            }
            if NoteTaker.availability == .available {
                for conversation in conversations(in: .transcribed) {
                    try Task.checkCancellation()
                    step("Writing notes")
                    try await summarize(conversation)
                    tally.summarized += 1
                    done += 1
                }
                step("Writing the day's digest")
                try await writeDigests()
            }
            lastFinished = .now
            lastOutcome = tally.summary
            onLog?("Processing finished in \(Int(Date.now.timeIntervalSince(started))) s: \(tally.summary)")
            return true
        } catch is CancellationError {
            onLog?("Processing stopped after \(Int(Date.now.timeIntervalSince(started))) s; it picks up where it left off")
            return false
        } catch PipelineError.rateLimited {
            onLog?("Notes paused: the on-device model is busy")
            return false
        } catch {
            lastError = error.localizedDescription
            onLog?("Processing stopped: \(error.localizedDescription)")
            return false
        }
    }

    private static func describe(_ backlog: Backlog) -> String {
        var parts: [String] = []
        if backlog.segments > 0 { parts.append("\(backlog.segments) recording\(backlog.segments == 1 ? "" : "s")") }
        if backlog.conversations > 0 { parts.append("\(backlog.conversations) to transcribe") }
        if backlog.notes > 0 { parts.append("\(backlog.notes) to summarize") }
        return parts.isEmpty ? "nothing waiting" : parts.joined(separator: ", ")
    }

    private func unloadModels() async {
        await scanner.unload()
        await separator.unload()
        await asr?.unload()
    }

    private func fail(_ conversation: Conversation, _ error: Error) {
        conversation.attempts += 1
        conversation.failure = error.localizedDescription
        // Give it another go next run; after three tries, stop.
        if conversation.attempts >= 3 { conversation.stage = .failed }
        try? context.save()
    }

    // MARK: - 1. speech

    /// Segments left open when the app was killed: count what made it to disk and close them.
    private func recoverInterrupted() {
        let open = openSegmentID()
        let stale = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { $0.isOpen }))) ?? []
        for segment in stale where segment.id != open {
            if let data = try? Data(contentsOf: segment.url) {
                let scan = ADTSFile.scan(data)
                segment.frames = scan.frames
                segment.bytes = data.count
            }
            segment.isOpen = false
            segment.closeReason = "interrupted"
        }
        try? context.save()
    }

    private func segmentsToScan() -> [AudioSegment] {
        var descriptor = FetchDescriptor<AudioSegment>(predicate: #Predicate { !$0.scanned && !$0.isOpen && !$0.audioDeleted })
        descriptor.sortBy = [SortDescriptor(\.start)]
        return (try? context.fetch(descriptor)) ?? []
    }

    private func scan(_ segment: AudioSegment) async throws {
        let url = segment.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            segment.scanned = true
            segment.audioDeleted = true
            try context.save()
            return
        }
        let samples = try await Task.detached(priority: .utility) { try AudioLoader.samples(from: url) }.value
        let regions = try await scanner.speech(in: samples)
        segment.regions = regions
        segment.speechSeconds = regions.reduce(0) { $0 + $1.duration }
        segment.scanned = true
        if regions.isEmpty && deleteSilence {
            try? FileManager.default.removeItem(at: url)
            segment.audioDeleted = true
        }
        try context.save()
    }

    // MARK: - 2. conversations

    private static let watermarkKey = "conversationsThrough"

    private func planConversations() {
        let defaults = UserDefaults.standard
        let watermark = defaults.object(forKey: Processor.watermarkKey) as? Date ?? .distantPast
        let lookback = watermark.addingTimeInterval(-3600)
        let segments = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { $0.scanned && $0.speechSeconds > 0 && $0.start > lookback }))) ?? []
        let regions = segments.flatMap { segment in
            segment.regions.map { DateInterval(start: segment.start.addingTimeInterval($0.start), end: segment.start.addingTimeInterval($0.end)) }
        }.filter { $0.start >= watermark }

        // Speech can only be judged as far as audio has been scanned. With nothing left to scan and no
        // recording going on, every conversation is over.
        let unscanned = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { !$0.scanned && !$0.audioDeleted }))) ?? []
        let horizon = unscanned.map(\.start).min() ?? (openSegmentID() == nil ? .distantFuture : .now)

        let result = ConversationPlanner(gap: TimeInterval(gapMinutes * 60)).plan(regions, horizon: horizon)
        for plan in result.closed {
            context.insert(Conversation(start: plan.span.start, end: plan.span.end, speechSeconds: plan.speech, regions: plan.regions))
        }
        if let through = result.through {
            defaults.set(through.addingTimeInterval(0.001), forKey: Processor.watermarkKey)
        }
        try? context.save()
        tally.found += result.closed.count
        tally.tooShort += result.dropped.reduce(0) { $0 + $1.speech }
    }

    #if DEBUG
    /// Test hook: plan conversations again from `date`, to pick up speech an older build dropped.
    func replan(from date: Date) {
        UserDefaults.standard.set(date, forKey: Processor.watermarkKey)
    }
    #endif

    private func conversations(in stage: Conversation.Stage) -> [Conversation] {
        let raw = stage.rawValue
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.stageRaw == raw })
        descriptor.sortBy = [SortDescriptor(\.start)]
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - 3. words and speakers

    private func loadedASR() async throws -> any SpeechEngine {
        let engine = asr ?? self.engine.makeEngine()
        asr = engine
        try await engine.prepare(placement)
        if self.engine == .parakeet { parakeetReady = true }
        return engine
    }

    /// The conversation's speech, cut from its segments, in pieces of at most 10 minutes (memory, and
    /// a stopping point if the run is interrupted).
    private func audioPieces(for conversation: Conversation) -> [[(url: URL, span: TimeSpan, source: TimeInterval)]] {
        let start = conversation.start.addingTimeInterval(-60), end = conversation.end.addingTimeInterval(60)
        let segments = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { $0.start < end && !$0.audioDeleted }))) ?? []
        let overlapping = segments.filter { $0.end > start }
        var pieces: [[(URL, TimeSpan, TimeInterval)]] = [[]]
        var length: TimeInterval = 0
        for region in conversation.regions {
            for segment in overlapping where segment.start < region.end && segment.end > region.start {
                let from = max(region.start, segment.start), to = min(region.end, segment.end)
                let span = TimeSpan(start: from.timeIntervalSince(segment.start), end: to.timeIntervalSince(segment.start))
                if length + span.duration > 600, !(pieces.last?.isEmpty ?? true) {
                    pieces.append([])
                    length = 0
                }
                pieces[pieces.count - 1].append((segment.url, span, from.timeIntervalSince(conversation.start)))
                length += span.duration
            }
        }
        return pieces.filter { !$0.isEmpty }.map { $0.map { (url: $0.0, span: $0.1, source: $0.2) } }
    }

    private func transcribe(_ conversation: Conversation) async throws {
        let engine = try await loadedASR()
        try await separator.prepare(placement)
        let profiles = ((try? context.fetch(FetchDescriptor<SpeakerProfile>())) ?? []).map(\.voiceprint)

        // Speakers are found per piece, then tied together across pieces by voice.
        var clusters: [(label: String, centroid: [Float], seconds: TimeInterval, loudness: Float)] = []
        var utterances: [Utterance] = []
        for piece in audioPieces(for: conversation) {
            try Task.checkCancellation()
            let audio = try await Task.detached(priority: .utility) {
                var audio = SplicedAudio()
                for part in piece { audio.append(try AudioLoader.samples(from: part.url, in: part.span), from: part.source) }
                return audio
            }.value
            let words = try await engine.transcribe(audio.samples).map { Word($0.text, audio.source($0.span), confidence: $0.confidence) }
            let turns = try await separator.turns(in: audio.samples)

            var relabel: [String: String] = [:]
            for cluster in Speakers.clusters(turns) {
                let loudness = Self.loudness(of: cluster.label, turns: turns, in: audio)
                if let index = clusters.firstIndex(where: { Speakers.cosine($0.centroid, cluster.centroid) >= 0.6 }) {
                    relabel[cluster.label] = clusters[index].label
                    clusters[index].seconds += cluster.seconds
                    clusters[index].loudness = max(clusters[index].loudness, loudness)
                } else {
                    let label = "S\(clusters.count + 1)"
                    relabel[cluster.label] = label
                    clusters.append((label, cluster.centroid, cluster.seconds, loudness))
                }
            }
            let mapped = turns.map { SpeakerTurn(speaker: relabel[$0.speaker] ?? $0.speaker, span: audio.source($0.span), embedding: $0.embedding) }
            utterances += Speakers.utterances(words: words, turns: mapped)
        }

        conversation.speakers = speakers(from: clusters, profiles: profiles)
        for line in conversation.lines { context.delete(line) }
        for (i, utterance) in utterances.enumerated() {
            let line = TranscriptLine(
                index: i,
                start: conversation.start.addingTimeInterval(utterance.span.start),
                end: conversation.start.addingTimeInterval(utterance.span.end),
                speaker: utterance.speaker, text: utterance.text
            )
            context.insert(line)
            line.conversation = conversation
        }
        conversation.engine = engine.name
        conversation.failure = nil
        conversation.stage = utterances.isEmpty ? .summarized : .transcribed
        if utterances.isEmpty { conversation.notesError = "No words were recognized." }
        try context.save()
    }

    private static func loudness(of label: String, turns: [SpeakerTurn], in audio: SplicedAudio) -> Float {
        var weighted: Float = 0, seconds: Float = 0
        for turn in turns where turn.speaker == label {
            weighted += audio.loudness(turn.span) * Float(turn.span.duration)
            seconds += Float(turn.span.duration)
        }
        return seconds > 0 ? weighted / seconds : 0
    }

    /// Names speakers: known voices by their profile; otherwise, without a "Me" profile yet, the loudest
    /// voice is taken to be the wearer (closest to the microphone) until they say otherwise.
    private func speakers(from found: [(label: String, centroid: [Float], seconds: TimeInterval, loudness: Float)], profiles: [Voiceprint]) -> [SpeakerInfo] {
        let clusters = Speakers.match(
            found.map { Speakers.Cluster(label: $0.label, centroid: $0.centroid, seconds: $0.seconds) }, to: profiles
        )
        var infos: [SpeakerInfo] = zip(found, clusters).map { raw, cluster in
            let profile = profiles.first { $0.id == cluster.voiceprint }
            return SpeakerInfo(
                label: raw.label, number: 0, name: profile.map { $0.isMe ? nil : $0.name } ?? nil, isMe: profile?.isMe ?? false,
                profile: profile?.id, centroid: raw.centroid, seconds: raw.seconds, loudness: raw.loudness
            )
        }
        if !profiles.contains(where: \.isMe) {
            let byLoudness = infos.indices.filter { infos[$0].seconds >= 3 }.sorted { infos[$0].loudness > infos[$1].loudness }
            if let loudest = byLoudness.first, byLoudness.count == 1 || infos[loudest].loudness >= 1.4 * infos[byLoudness[1]].loudness {
                infos[loudest].isMe = true
                infos[loudest].guessedMe = true
            }
        }
        var number = 0
        for i in infos.indices.sorted(by: { infos[$0].seconds > infos[$1].seconds }) where !infos[i].isMe {
            number += 1
            infos[i].number = number
        }
        // Profiles learn from confident matches.
        for cluster in clusters where (cluster.similarity ?? 0) >= 0.75 {
            if let id = cluster.voiceprint, let profile = try? context.fetch(FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == id })).first {
                var print = profile.voiceprint
                print.learn(cluster.centroid)
                profile.embedding = print.embedding
                profile.samples = print.samples
            }
        }
        return infos
    }

    // MARK: - 4. notes

    private func summarize(_ conversation: Conversation) async throws {
        let origin = conversation.start
        let lines = conversation.sortedLines
        let bookmarks = Self.bookmarks(for: conversation, context: context)
        let utterances = lines.map { line in
            let marked = bookmarks.contains { Self.line(line, covers: $0) }
            return Utterance(
                speaker: line.speaker,
                span: TimeSpan(start: line.start.timeIntervalSince(origin), end: line.end.timeIntervalSince(origin)),
                text: line.text + (marked ? " [bookmarked]" : "")
            )
        }
        do {
            let notes = try await NoteTaker().notes(for: utterances, names: conversation.speakerNames)
            apply(notes, to: conversation, lines: lines)
        } catch let error as PipelineError {
            switch error {
            case .rateLimited, .cancelled: throw error
            default: conversation.notesError = error.localizedDescription
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            conversation.notesError = error.localizedDescription
        }
        conversation.stage = .summarized
        try context.save()
    }

    private func apply(_ notes: ConversationNotes, to conversation: Conversation, lines: [TranscriptLine]) {
        conversation.title = notes.title
        conversation.summary = notes.summary
        conversation.topics = notes.topics
        conversation.soundsLikeMedia = notes.soundsLikeMedia
        conversation.notesError = nil
        for todo in conversation.todos { context.delete(todo) }
        // Nothing from the TV goes in the inbox.
        guard !notes.soundsLikeMedia else { return }
        for item in notes.actionItems where !item.task.isEmpty {
            let todo = TodoItem(item, quoteTime: Self.locate(item.quote, in: lines), created: conversation.end)
            context.insert(todo)
            todo.conversation = conversation
        }
    }

    /// Double presses on the Bee during a conversation: "remember this".
    static func bookmarks(for conversation: Conversation, context: ModelContext) -> [Date] {
        let code = Int(EventCode.buttonDoublePress.rawValue)
        let start = conversation.start.addingTimeInterval(-5), end = conversation.end.addingTimeInterval(5)
        let entries = (try? context.fetch(FetchDescriptor<LogEntry>(predicate: #Predicate { $0.code == code && $0.timestamp >= start && $0.timestamp <= end }))) ?? []
        return entries.map(\.timestamp)
    }

    /// A press lands a moment after the words it's about.
    static func line(_ line: TranscriptLine, covers bookmark: Date) -> Bool {
        bookmark >= line.start.addingTimeInterval(-2) && bookmark <= line.end.addingTimeInterval(4)
    }

    /// The transcript line a quote came from, by its first few words.
    static func locate(_ quote: String, in lines: [TranscriptLine]) -> Date? {
        let words = quote.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(5)
        guard !words.isEmpty else { return nil }
        let needle = words.joined(separator: " ")
        return lines.first { line in
            line.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ").contains(needle)
        }?.start
    }

    private func writeDigests(announce: Bool = true) async throws {
        let summarized = Conversation.Stage.summarized.rawValue
        let all = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.stageRaw == summarized && !$0.soundsLikeMedia }))) ?? []
        let calendar = Calendar.current
        let days = Dictionary(grouping: all.filter { $0.title != nil }) { calendar.startOfDay(for: $0.start) }
        let existing = Dictionary(((try? context.fetch(FetchDescriptor<DayNote>())) ?? []).map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for (day, conversations) in days where existing[day]?.conversationCount != conversations.count {
            try Task.checkCancellation()
            let entries = conversations.compactMap { c -> (start: Date, notes: ConversationNotes)? in
                guard let title = c.title, let summary = c.summary else { return nil }
                let items = c.todos.map { ActionItemNote(task: $0.task, owner: $0.owner, due: $0.due, quote: $0.quote) }
                return (c.start, ConversationNotes(title: title, summary: summary, actionItems: items, topics: c.topics, soundsLikeMedia: false))
            }
            do {
                let digest = try await NoteTaker().digest(entries)
                let note: DayNote
                if let existing = existing[day] {
                    existing.update(digest, conversationCount: conversations.count)
                    note = existing
                } else {
                    note = DayNote(day: day, digest: digest, conversationCount: conversations.count)
                    context.insert(note)
                }
                try context.save()
                if announce { onDigest?(note) }
            } catch PipelineError.declined {
                continue
            }
        }
    }

    // MARK: - speakers, from the transcript screen

    /// "This is me" / "This is Sam": saves the voice and renames the speaker here.
    func identify(_ label: String, in conversation: Conversation, asMe: Bool, name: String? = nil) {
        var speakers = conversation.speakers
        guard let index = speakers.firstIndex(where: { $0.label == label }) else { return }
        let centroid = speakers[index].centroid
        let profiles = (try? context.fetch(FetchDescriptor<SpeakerProfile>())) ?? []
        let existing = asMe ? profiles.first(where: \.isMe) : profiles.first { !$0.isMe && $0.name.caseInsensitiveCompare(name ?? "") == .orderedSame }
        let profile: SpeakerProfile
        if let existing {
            var print = existing.voiceprint
            print.learn(centroid)
            existing.embedding = print.embedding
            existing.samples = print.samples
            profile = existing
        } else {
            profile = SpeakerProfile(Voiceprint(name: asMe ? "Me" : (name ?? "Someone"), isMe: asMe, embedding: centroid))
            context.insert(profile)
        }
        if asMe {
            for i in speakers.indices where speakers[i].isMe { speakers[i].isMe = false; speakers[i].guessedMe = false }
        }
        speakers[index].isMe = asMe
        speakers[index].guessedMe = false
        speakers[index].name = asMe ? nil : name
        speakers[index].profile = profile.id
        conversation.speakers = speakers
        try? context.save()
    }

    /// The loudest voice wasn't the wearer after all.
    func notMe(_ label: String, in conversation: Conversation) {
        var speakers = conversation.speakers
        guard let index = speakers.firstIndex(where: { $0.label == label }) else { return }
        speakers[index].isMe = false
        speakers[index].guessedMe = false
        speakers[index].number = (speakers.map(\.number).max() ?? 0) + 1
        conversation.speakers = speakers
        try? context.save()
    }

    /// Notes again (after renaming speakers, say).
    func resummarize(_ conversation: Conversation) async {
        guard conversation.stage == .summarized, !conversation.lines.isEmpty else { return }
        conversation.stage = .transcribed
        try? context.save()
        await process()
    }

    func retranscribe(_ conversation: Conversation) async {
        conversation.stage = .pending
        conversation.attempts = 0
        try? context.save()
        await process()
    }

    // MARK: - deleting

    func deleteEverything() {
        try? FileManager.default.removeItem(at: Library.recordings)
        try? FileManager.default.createDirectory(at: Library.recordings, withIntermediateDirectories: true)
        let open = openSegmentID()
        for segment in (try? context.fetch(FetchDescriptor<AudioSegment>())) ?? [] where segment.id != open {
            context.delete(segment)
        }
        try? context.delete(model: TranscriptLine.self)
        try? context.delete(model: TodoItem.self)
        try? context.delete(model: Conversation.self)
        try? context.delete(model: DayNote.self)
        UserDefaults.standard.removeObject(forKey: Processor.watermarkKey)
        try? context.save()
    }

    /// Deletes a conversation with its transcript and to-dos. Its day's digest may quote it, so that's
    /// written again from the conversations left. With `withAudio`, its stretch of audio goes too: a
    /// recording with nothing else in it is deleted, one shared with other speech is cut.
    func delete(_ conversation: Conversation, withAudio: Bool) {
        if withAudio {
            // A second either side for the voice detector's padding; neighbors are at least the gap away.
            cutAudio(from: conversation.start.addingTimeInterval(-1), to: conversation.end.addingTimeInterval(1))
        }
        let day = Calendar.current.startOfDay(for: conversation.start)
        context.delete(conversation)
        try? context.delete(model: DayNote.self, where: #Predicate { $0.day == day })
        try? context.save()
        // A run in progress writes digests at its end.
        if run == nil, NoteTaker.availability == .available {
            Task { try? await writeDigests(announce: false) }
        }
    }

    private func cutAudio(from start: Date, to end: Date) {
        let segments = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { $0.start < end && !$0.audioDeleted && !$0.isOpen }))) ?? []
        for segment in segments where segment.end > start {
            do {
                try cut(TimeSpan(start: start.timeIntervalSince(segment.start), end: end.timeIntervalSince(segment.start)), from: segment)
            } catch {
                onLog?("Couldn't delete the audio in \(segment.file): \(error.localizedDescription)")
            }
        }
    }

    private func cut(_ span: TimeSpan, from segment: AudioSegment) throws {
        guard FileManager.default.fileExists(atPath: segment.url.path) else {
            segment.audioDeleted = true
            return
        }
        let data = try Data(contentsOf: segment.url)
        let frames = ADTSFile.frames(in: data)
        let frameDuration = Double(ADTSHeader.samplesPerFrame) / Double(max(segment.sampleRate, 1))
        // Before speech detection has run, everything left over counts as speech.
        let speech = segment.scanned ? segment.regions : [TimeSpan(start: 0, end: Double(frames.count) * frameDuration)]
        let pieces = frames.isEmpty ? [] : AudioCut.remove(span, frames: frames.count, frameDuration: frameDuration, speech: speech)
        if pieces.count == 1 && pieces[0].frames.count == frames.count { return }
        guard !pieces.isEmpty else {
            try FileManager.default.removeItem(at: segment.url)
            segment.audioDeleted = true
            return
        }
        let start = segment.start, lastArrival = segment.lastArrival
        for (index, piece) in pieces.enumerated() {
            let bytes = data[frames[piece.frames.lowerBound].lowerBound..<frames[piece.frames.upperBound - 1].upperBound]
            let row: AudioSegment
            if index == 0 {
                row = segment
            } else {
                row = AudioSegment(remainderOf: segment, file: (segment.file as NSString).deletingPathExtension + "-\(Int(piece.offset))s.aac")
                context.insert(row)
            }
            try Data(bytes).write(to: row.url, options: .atomic)
            row.start = start.addingTimeInterval(piece.offset)
            row.frames = piece.frames.count
            row.bytes = bytes.count
            row.lastArrival = piece.frames.upperBound == frames.count ? lastArrival : row.end
            if segment.scanned {
                row.regions = piece.speech
                row.speechSeconds = piece.speech.reduce(0) { $0 + $1.duration }
            }
        }
    }
}
