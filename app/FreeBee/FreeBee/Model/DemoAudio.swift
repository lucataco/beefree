@preconcurrency import AVFoundation
import BeeProtocol
import Foundation

/// What the demo Bee hears: a short scripted conversation in two system voices, encoded the way the Bee
/// encodes (AAC-LC, 16 kHz, mono, ADTS), so demo mode exercises capture, transcription and notes.
enum DemoAudio {
    private static let script: [(wearer: Bool, text: String)] = [
        (true, "Hey Sam, do you have a minute about the launch?"),
        (false, "Sure. I looked at the plan last night. I think the beta should move to the fifteenth."),
        (true, "That works for me. I'll update the timeline and send it to the team by Friday."),
        (false, "Great. Can you also book the room for the review on Monday morning?"),
        (true, "Yes, I'll book it today. Let's go over the pricing slides then too."),
        (false, "Perfect. I'll bring the numbers from the survey."),
    ]

    private static let cache = URL.cachesDirectory.appendingPathComponent("demo-conversation.aac")

    /// ADTS frames, made once and cached. Empty if the system has no voices (then the demo streams noise).
    static func frames() async -> [Data] {
        if let data = try? Data(contentsOf: cache), let frames = split(data), !frames.isEmpty { return frames }
        do {
            let pcm = try await speak()
            let frames = try encode(pcm)
            try? frames.reduce(Data(), +).write(to: cache)
            return frames
        } catch {
            return []
        }
    }

    /// Two seconds of encoded silence, for the demo Bee to stream once the conversation is over.
    static func silence() -> [Data] {
        (try? encode([Float](repeating: 0, count: 32_000))) ?? []
    }

    private static func split(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var offset = 0
        var frames: [Data] = []
        while let header = ADTSHeader(bytes, at: offset), offset + header.frameLength <= bytes.count {
            frames.append(Data(bytes[offset..<offset + header.frameLength]))
            offset += header.frameLength
        }
        return offset == bytes.count ? frames : nil
    }

    /// Speaks the script into 16 kHz mono samples, with pauses between turns and a lead-in of silence.
    private static func speak() async throws -> [Float] {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let wearer = voices.first { $0.gender == .male } ?? voices.first
        let other = voices.first { $0.gender == .female && $0 != wearer } ?? voices.last
        var samples = [Float](repeating: 0, count: 16_000)
        for line in script {
            let utterance = AVSpeechUtterance(string: line.text)
            utterance.voice = line.wearer ? wearer : other
            // The wearer is nearest the microphone: louder.
            utterance.volume = line.wearer ? 1.0 : 0.55
            samples += try await render(utterance)
            samples += [Float](repeating: 0, count: 8_000)
        }
        return samples + [Float](repeating: 0, count: 16_000)
    }

    private static func render(_ utterance: AVSpeechUtterance) async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let buffers: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            var collected: [AVAudioPCMBuffer] = []
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    finished = true
                    continuation.resume(returning: collected)
                    return
                }
                collected.append(pcm)
            }
        }
        withExtendedLifetime(synthesizer) {}
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: first.format, to: target) else { return [] }
        var out: [Float] = []
        for buffer in buffers {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 512
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if let channel = converted.floatChannelData?[0] {
                out += UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
            }
        }
        return out
    }

    /// AAC-LC at 32 kbps, one ADTS frame per 1024 samples.
    private static func encode(_ samples: [Float]) throws -> [Data] {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { return [] }
        var description = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        guard let aac = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: pcm, to: aac) else { return [] }
        converter.bitRate = 32_000
        guard let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)

        var frames: [Data] = []
        var supplied = false
        while true {
            let output = AVAudioCompressedBuffer(format: aac, packetCapacity: 32, maximumPacketSize: max(converter.maximumOutputPacketSize, 1024))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let descriptions = output.packetDescriptions {
                for i in 0..<Int(output.packetCount) {
                    let packet = descriptions[i]
                    let payload = Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
                    frames.append(ADTSHeader.header(payloadLength: payload.count) + payload)
                }
            }
            if status == .endOfStream || status == .error || (output.packetCount == 0 && supplied) { break }
        }
        return frames
    }
}
