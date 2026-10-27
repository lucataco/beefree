@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech

/// Turns 16 kHz mono samples into timed words.
public protocol SpeechEngine: Actor {
    nonisolated var name: String { get }
    /// Loads (and on first use downloads) what the engine needs. Safe to call repeatedly.
    func prepare(_ placement: ComputePlacement) async throws
    /// Word times are seconds from the start of `samples`.
    func transcribe(_ samples: [Float]) async throws -> [Word]
    /// Frees the model (hundreds of MB). The next `transcribe` loads it again.
    func unload()
}

public enum EngineChoice: String, Sendable, Codable, CaseIterable, Identifiable {
    /// NVIDIA Parakeet TDT 0.6B v3 on Core ML, via FluidAudio. The most accurate free on-device model;
    /// about 480 MB, downloaded once.
    case parakeet
    /// Apple's SpeechTranscriber. Built in (the OS manages the model), somewhat less accurate.
    case apple

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .apple: "Apple Speech"
        }
    }

    public func makeEngine() -> any SpeechEngine {
        switch self {
        case .parakeet: ParakeetEngine()
        case .apple: AppleSpeechEngine()
        }
    }
}

/// Parakeet TDT v3 through FluidAudio. Load it once per batch: a cold load is seconds, a warm one isn't.
public actor ParakeetEngine: SpeechEngine {
    public nonisolated let name = "Parakeet v3"
    private var manager: AsrManager?
    private var placement: ComputePlacement?

    public init() {}

    /// Already downloaded, so preparing won't use the network.
    public nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Downloads the model (about 480 MB) without loading it.
    public static func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        do {
            try await AsrModels.download(version: .v3) { progress?($0.fractionCompleted) }
        } catch {
            if error.isCancellation { throw CancellationError() }
            throw PipelineError.modelUnavailable("Couldn't download Parakeet: \(error.localizedDescription)")
        }
    }

    public func prepare(_ placement: ComputePlacement) async throws {
        if manager != nil, self.placement == placement { return }
        do {
            let configuration = AsrModels.defaultConfiguration()
            configuration.computeUnits = placement.units
            let models = try await AsrModels.downloadAndLoad(configuration: configuration, version: .v3, encoderComputeUnits: placement.units)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            self.placement = placement
        } catch {
            if error.isCancellation || Task.isCancelled { throw CancellationError() }
            throw PipelineError.modelUnavailable("Couldn't load Parakeet: \(error.localizedDescription)")
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> [Word] {
        if manager == nil { try await prepare(.foreground) }
        guard let manager, samples.count >= AudioLoader.sampleRate / 4 else { return [] }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [Word(text, TimeSpan(start: 0, end: result.duration), confidence: result.confidence)]
        }
        let confidence = Dictionary(timings.map { ($0.startTime, $0.confidence) }, uniquingKeysWith: { a, _ in a })
        return buildWordTimings(from: timings).map {
            Word($0.word, TimeSpan(start: $0.startTime, end: $0.endTime), confidence: confidence[$0.startTime])
        }
    }

    public func unload() {
        manager = nil
        placement = nil
    }
}

/// Apple's SpeechTranscriber (Speech framework). No download of our own; the system installs the locale's
/// model once. Its work may run outside our process, which is why it's the candidate for background drafts.
public actor AppleSpeechEngine: SpeechEngine {
    public nonisolated let name = "Apple Speech"
    private var locale: Locale?

    public init() {}

    public func prepare(_ placement: ComputePlacement) async throws {
        guard locale == nil else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw PipelineError.modelUnavailable("Apple Speech doesn't support \(Locale.current.identifier).")
        }
        let transcriber = Self.transcriber(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        self.locale = locale
    }

    public func transcribe(_ samples: [Float]) async throws -> [Word] {
        try await prepare(.foreground)
        guard let locale, !samples.isEmpty else { return [] }
        let transcriber = Self.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioLoader.sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw PipelineError.unreadableAudio("couldn't build an input buffer")
        }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let inputs = try converter.convert(buffer, at: nil) + converter.flush()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for input in inputs { continuation.yield(input) }
        continuation.finish()

        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                words += Self.words(in: result.text)
            }
            return words
        }
        do {
            _ = try await analyzer.analyzeSequence(stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    public func unload() {}

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// The text comes as runs tagged with their audio time range; turn each into a word.
    private static func words(in text: AttributedString) -> [Word] {
        var words: [Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            guard let range = run.audioTimeRange else {
                // No timing: glue it to the previous word.
                if !words.isEmpty { words[words.count - 1].text += piece }
                continue
            }
            // Several words in one run share its range.
            let span = TimeSpan(start: range.start.seconds, end: range.end.seconds)
            for part in piece.split(separator: " ") {
                words.append(Word(String(part), span))
            }
        }
        return words
    }
}
