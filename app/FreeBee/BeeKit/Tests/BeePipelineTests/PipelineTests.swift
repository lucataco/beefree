@testable import BeePipeline
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func region(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval {
    DateInterval(start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
}

@Test func groupsSpeechIntoConversations() {
    let planner = ConversationPlanner(gap: 120, minimumSpeech: 8)
    let regions = [
        region(0, 5), region(10, 20), region(60, 70),   // one conversation, 25 s of speech
        region(400, 403),                                 // a lone 3 s remark: dropped
        region(900, 930), region(1000, 1010),            // another, still open at the horizon
    ]
    let result = planner.plan(regions.shuffled(), horizon: t0.addingTimeInterval(1060))
    #expect(result.closed.count == 1)
    #expect(result.closed[0].span == region(0, 70))
    #expect(result.closed[0].speech == 25)
    #expect(result.open?.span == region(900, 1010))
    #expect(result.dropped.map(\.span) == [region(400, 403)])
    // The dropped remark is decided too, so planning resumes after it.
    #expect(result.through == t0.addingTimeInterval(403))

    // Once capture stops, the last one closes too.
    let all = planner.plan(regions, horizon: .distantFuture)
    #expect(all.closed.count == 2)
    #expect(all.open == nil)
}

@Test func keepsAShortNoteToSelf() {
    // 7.7 s of speech in a 12 s recording: the Bee only records when asked, so that's kept.
    let note = ConversationPlanner().plan([region(0, 3.5), region(5, 9.2)], horizon: .distantFuture)
    #expect(note.closed.count == 1)
    #expect(note.dropped.isEmpty)
    // A lone cough isn't.
    let cough = ConversationPlanner().plan([region(0, 0.6)], horizon: .distantFuture)
    #expect(cough.closed.isEmpty)
    #expect(cough.dropped.count == 1)
}

@Test func cutsOneConversationOutOfARecording() {
    let frame = 0.064
    let speech = [TimeSpan(start: 10, end: 20), TimeSpan(start: 200, end: 230), TimeSpan(start: 500, end: 520)]
    // Deleting the middle conversation keeps both neighbors, each with its speech moved to its new start.
    let pieces = AudioCut.remove(TimeSpan(start: 199, end: 231), frames: 9375, frameDuration: frame, speech: speech)
    #expect(pieces.count == 2)
    #expect(pieces[0].frames == 0..<3109)
    #expect(pieces[0].offset == 0)
    #expect(pieces[0].speech == [TimeSpan(start: 10, end: 20)])
    #expect(pieces[1].frames == 3610..<9375)
    #expect(abs(pieces[1].speech[0].start - (500 - pieces[1].offset)) < 1e-9)
    // The last conversation in it, with only silence before: nothing is left.
    let only = AudioCut.remove(TimeSpan(start: 0, end: 600), frames: 9375, frameDuration: frame, speech: speech)
    #expect(only.isEmpty)
    let rest = AudioCut.remove(TimeSpan(start: 9, end: 21), frames: 400, frameDuration: frame, speech: [TimeSpan(start: 10, end: 20)])
    #expect(rest.isEmpty)
    // A recording the cut doesn't reach stays whole.
    let untouched = AudioCut.remove(TimeSpan(start: 700, end: 710), frames: 9375, frameDuration: frame, speech: speech)
    #expect(untouched == [AudioCut.Piece(frames: 0..<9375, offset: 0, speech: speech)])
}

@Test func splicesAndMapsBack() {
    var audio = SplicedAudio()
    audio.append([Float](repeating: 0.5, count: 16_000), from: 10)   // 1 s of speech at 10 s
    audio.append([Float](repeating: 0.1, count: 32_000), from: 100)  // 2 s at 100 s
    #expect(abs(audio.duration - 3.3) < 1e-9)
    #expect(audio.pieces.map(\.offset) == [0, 1.3])
    #expect(abs(audio.sourceTime(0.5) - 10.5) < 1e-9)
    #expect(abs(audio.sourceTime(2.3) - 101) < 1e-9)
    // Inside the pause: the end of the piece before it.
    #expect(abs(audio.sourceTime(1.1) - 11) < 1e-9)
    #expect(abs(audio.loudness(TimeSpan(start: 0, end: 1)) - 0.5) < 1e-4)
    #expect(abs(audio.loudness(TimeSpan(start: 1.3, end: 3.3)) - 0.1) < 1e-4)
}

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> Word {
    Word(text, TimeSpan(start: start, end: end))
}

@Test func assignsWordsToSpeakers() {
    let words = [
        word("Can", 0.0, 0.2), word("you", 0.25, 0.4), word("send", 0.45, 0.7), word("it", 0.75, 0.9), word("?", 0.9, 0.95),
        word("Sure", 1.3, 1.6), word(",", 1.6, 1.62), word("tomorrow", 1.7, 2.2), word(".", 2.2, 2.25),
        word("Thanks", 5.0, 5.4),
    ]
    let turns = [
        SpeakerTurn(speaker: "S1", span: TimeSpan(start: 0, end: 1.0), embedding: []),
        SpeakerTurn(speaker: "S2", span: TimeSpan(start: 1.2, end: 2.4), embedding: []),
        SpeakerTurn(speaker: "S1", span: TimeSpan(start: 4.9, end: 5.5), embedding: []),
    ]
    let out = Speakers.utterances(words: words, turns: turns)
    #expect(out.map(\.speaker) == ["S1", "S2", "S1"])
    #expect(out.map(\.text) == ["Can you send it?", "Sure, tomorrow.", "Thanks"])
    #expect(out[1].span == TimeSpan(start: 1.3, end: 2.25))
}

@Test func splitsOnLongPausesWithinOneSpeaker() {
    let words = [word("One", 0, 0.3), word("two", 0.4, 0.6), word("three", 4.0, 4.3)]
    let out = Speakers.utterances(words: words, turns: [SpeakerTurn(speaker: "S1", span: TimeSpan(start: 0, end: 5), embedding: [])])
    #expect(out.map(\.text) == ["One two", "three"])
}

@Test func matchesVoiceprints() {
    let me = Voiceprint(name: "Me", isMe: true, embedding: [1, 0, 0, 0.1])
    let sam = Voiceprint(name: "Sam", isMe: false, embedding: [0, 1, 0, 0])
    let turns = [
        SpeakerTurn(speaker: "S1", span: TimeSpan(start: 0, end: 10), embedding: [0.9, 0.1, 0.05, 0.1]),
        SpeakerTurn(speaker: "S1", span: TimeSpan(start: 20, end: 25), embedding: [1, 0, 0, 0]),
        SpeakerTurn(speaker: "S2", span: TimeSpan(start: 10, end: 14), embedding: [0.1, 0.95, 0.1, 0]),
        SpeakerTurn(speaker: "S3", span: TimeSpan(start: 14, end: 15), embedding: [0, 0, 1, 0]),
    ]
    let clusters = Speakers.match(Speakers.clusters(turns), to: [me, sam])
    #expect(clusters.map(\.label) == ["S1", "S2", "S3"]) // by talk time
    #expect(clusters[0].voiceprint == me.id)
    #expect(clusters[1].voiceprint == sam.id)
    #expect(clusters[2].voiceprint == nil)

    var learned = me
    learned.learn([0, 1, 0, 0])
    #expect(learned.samples == 2)
    #expect(Speakers.cosine(learned.embedding, [1, 0, 0, 0]) < 0.99)
}

@Test func chunksAtSpeakerTurns() async throws {
    let lines = (0..<40).map { "Speaker \($0 % 2 + 1): " + String(repeating: "word ", count: 30) }
    let chunks = try await NoteTaker.chunk(lines, budget: 300)
    #expect(chunks.count > 1)
    #expect(chunks.joined(separator: "\n") == lines.joined(separator: "\n"))
    #expect(chunks.allSatisfy { $0.utf8.count / 3 <= 300 + 60 })
}

// MARK: - the real capture

/// `captures/` at the repository root (`beekit audio --out-dir ../captures` from `mac/`). Git-ignored.
private let macDecode = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("captures/20261020-201740.aac")
private let haveCapture = FileManager.default.fileExists(atPath: macDecode.path)

/// AVFoundation reads the archived ADTS as-is: 698 frames of 1024 samples at 16 kHz.
@Test(.enabled(if: haveCapture)) func decodesArchivedADTS() throws {
    let samples = try AudioLoader.samples(from: macDecode)
    #expect(abs(samples.count - 698 * 1024) <= 2048)
    let peak = samples.reduce(0) { max($0, abs($1)) }
    #expect(peak > 0.01 && peak <= 1.5)

    let part = try AudioLoader.samples(from: macDecode, in: TimeSpan(start: 10, end: 12.5))
    #expect(abs(part.count - 40_000) <= 1024)
}

/// Downloads the models (about 500 MB, once) and runs VAD, Parakeet and diarization on the capture.
/// Opt in: `BEE_MODEL_TESTS=1 swift test --filter runsTheModels`.
@Test(.enabled(if: haveCapture && ProcessInfo.processInfo.environment["BEE_MODEL_TESTS"] == "1"))
func runsTheModels() async throws {
    let samples = try AudioLoader.samples(from: macDecode)
    let scanner = SpeechScanner()
    let regions = try await scanner.speech(in: samples)
    print("speech regions:", regions.map { String(format: "%.1f–%.1f", $0.start, $0.end) }.joined(separator: " "))
    #expect(!regions.isEmpty)

    let engine = ParakeetEngine()
    try await engine.prepare(.foreground)
    let words = try await engine.transcribe(samples)
    #expect(!words.isEmpty)

    let separator = SpeakerSeparator()
    let turns = try await separator.turns(in: samples)
    print("speakers:", Set(turns.map(\.speaker)).sorted(), "turns:", turns.count)

    for utterance in Speakers.utterances(words: words, turns: turns) {
        print(String(format: "[%5.1f] %@: %@", utterance.span.start, utterance.speaker, utterance.text))
    }

    if NoteTaker.availability == .available {
        let utterances = Speakers.utterances(words: words, turns: turns)
        let notes = try await NoteTaker().notes(for: utterances, names: [:])
        print("title:", notes.title)
        print("summary:", notes.summary)
        print("tasks:", notes.actionItems.map(\.task))
    } else {
        print("Foundation Models:", NoteTaker.availability)
    }
}
