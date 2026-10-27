@preconcurrency import AVFoundation
import CoreML
import Foundation

/// A span of audio, in seconds from the start of whatever it's relative to.
public struct TimeSpan: Hashable, Sendable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
    public var mid: TimeInterval { (start + end) / 2 }

    public func overlap(with other: TimeSpan) -> TimeInterval {
        max(0, min(end, other.end) - max(start, other.start))
    }

    public func shifted(by offset: TimeInterval) -> TimeSpan {
        TimeSpan(start: start + offset, end: end + offset)
    }
}

/// One recognized word with its timing.
public struct Word: Hashable, Sendable, Codable {
    public var text: String
    public var span: TimeSpan
    public var confidence: Float?

    public init(_ text: String, _ span: TimeSpan, confidence: Float? = nil) {
        self.text = text
        self.span = span
        self.confidence = confidence
    }
}

/// A stretch of speech by one speaker, as diarization found it. `speaker` is local to one run.
public struct SpeakerTurn: Hashable, Sendable {
    public var speaker: String
    public var span: TimeSpan
    /// The speaker embedding (WeSpeaker, 256-d) for this turn.
    public var embedding: [Float]

    public init(speaker: String, span: TimeSpan, embedding: [Float]) {
        self.speaker = speaker
        self.span = span
        self.embedding = embedding
    }
}

/// What someone said, in one breath or a few.
public struct Utterance: Hashable, Sendable, Codable {
    public var speaker: String
    public var span: TimeSpan
    public var text: String

    public init(speaker: String, span: TimeSpan, text: String) {
        self.speaker = speaker
        self.span = span
        self.text = text
    }
}

/// Where Core ML may run. The Neural Engine is off limits in the background on iOS 27 without the
/// Background Inference entitlement, and there's no background GPU on iPhone, so background work is CPU.
public enum ComputePlacement: String, Sendable, Codable {
    /// In the foreground: CPU and Neural Engine.
    case foreground
    /// In the background: CPU only.
    case background

    public var units: MLComputeUnitsValue {
        switch self {
        case .foreground: .cpuAndNeuralEngine
        case .background: .cpuOnly
        }
    }
}

/// `MLComputeUnits` without making every client import Core ML.
public typealias MLComputeUnitsValue = MLComputeUnits

public enum PipelineError: Error, LocalizedError, Equatable {
    case unreadableAudio(String)
    case modelUnavailable(String)
    case notesUnavailable(String)
    /// Foundation Models is throttling us. Try again after the date, if there is one.
    case rateLimited(Date?)
    /// The model declined (guardrails or refusal). Not worth retrying with the same text.
    case declined(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unreadableAudio(reason): "Couldn't read the audio: \(reason)"
        case let .modelUnavailable(reason): reason
        case let .notesUnavailable(reason): reason
        case .rateLimited: "The on-device model is busy. FreeBee will try again later."
        case let .declined(reason): "The on-device model wouldn't summarize this conversation (\(reason))."
        case .cancelled: "Stopped."
        }
    }
}

extension Error {
    /// Stopping a run cancels downloads and model loads; that's a stop, not a failure.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled || (self as NSError).code == NSURLErrorCancelled
    }
}

/// Decodes archived ADTS (or anything AVFoundation reads) to the 16 kHz mono Float32 the models take.
public enum AudioLoader {
    public static let sampleRate = 16_000

    /// The whole file, or just `span` (seconds from the start of the file).
    public static func samples(from url: URL, in span: TimeSpan? = nil) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PipelineError.unreadableAudio(error.localizedDescription)
        }
        let input = file.processingFormat
        let rate = input.sampleRate
        var first: AVAudioFramePosition = 0
        var count = file.length
        if let span {
            first = max(0, min(file.length, AVAudioFramePosition(span.start * rate)))
            count = max(0, min(file.length - first, AVAudioFramePosition(span.duration * rate)))
        }
        guard count > 0 else { return [] }
        file.framePosition = first

        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false) else {
            throw PipelineError.unreadableAudio("no 16 kHz format")
        }
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else {
            throw PipelineError.unreadableAudio("couldn't allocate a buffer")
        }
        let converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(count) * Double(sampleRate) / rate) + 1024)
        var remaining = count
        while remaining > 0 {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
            } catch {
                // A truncated last frame (the app was killed mid-write) ends the file early.
                break
            }
            guard buffer.frameLength > 0 else { break }
            remaining -= AVAudioFramePosition(buffer.frameLength)
            if let converter {
                samples += try convert(buffer, with: converter, to: output)
            } else if let channel = buffer.floatChannelData?[0] {
                samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            }
        }
        return samples
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) throws -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw PipelineError.unreadableAudio(error.localizedDescription) }
        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
