import BeeKit
import BeeProtocol
import Foundation
import Testing

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beekit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func frames(_ count: Int) -> [Data] {
    (0..<count).map { i in
        let payload = Data(repeating: UInt8(truncatingIfNeeded: i), count: 220 + i % 90)
        return ADTSHeader.header(payloadLength: payload.count) + payload
    }
}

private let format = ADTSHeader([UInt8](ADTSHeader.header(payloadLength: 10) + Data(count: 10)))!

@MainActor
@Test func recorderWritesRollsAndSplitsOnPauses() throws {
    let directory = try temporaryDirectory()
    let recorder = AudioRecorder(directory: directory)
    recorder.segmentLength = 64 * 0.064 // 64 frames
    var closed: [(AudioRecorder.Segment, AudioRecorder.CloseReason)] = []
    recorder.onClose = { closed.append(($0, $1)) }

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let all = frames(100)
    // 100 frames in batches of 2, arriving every 128 ms: 64 fill the first segment, 36 go in the next.
    for (i, batch) in stride(from: 0, to: 100, by: 2).map({ Array(all[$0..<$0 + 2]) }).enumerated() {
        try recorder.append(batch, format: format, deviceID: "BEE", at: start.addingTimeInterval(Double(i + 1) * 0.128))
    }
    #expect(closed.count == 1)
    #expect(closed.first?.1 == .rolled)
    #expect(closed.first?.0.frames == 64)

    // A 10 s pause, then more audio: the open segment closes as idle.
    try recorder.append(Array(all[0..<2]), format: format, deviceID: "BEE", lostPackets: 1, at: start.addingTimeInterval(20))
    #expect(closed.count == 2)
    #expect(closed.last?.1 == .idle)
    #expect(closed.last?.0.frames == 36)
    recorder.close(.disconnected)
    #expect(closed.last?.1 == .disconnected)
    #expect(closed.last?.0.lostPackets == 1)

    // Each file holds exactly its frames, unchanged.
    let first = try Data(contentsOf: recorder.url(for: closed[0].0))
    #expect(first == all[0..<64].reduce(Data(), +))
    #expect(ADTSFile.scan(try Data(contentsOf: recorder.url(for: closed[1].0))).frames == 36)
    let segment = closed[0].0
    #expect(abs(segment.duration - 64 * 0.064) < 1e-6)
    #expect(segment.start < start.addingTimeInterval(0.128))
}

@MainActor
@Test func capturesTheSimulatedBee() async throws {
    let directory = try temporaryDirectory()
    let bee = SimulatedBee(latency: .milliseconds(2))
    let client = BeeClient(transport: bee)
    let recorder = AudioRecorder(directory: directory)
    let capture = AudioCapture(recorder: recorder)
    var verified = false
    capture.onVerified = { verified = true }
    var closed: [AudioRecorder.Segment] = []
    recorder.onClose = { segment, _ in closed.append(segment) }

    let nonce = try await client.openSession(bee.demoToken)
    try await client.setState(.recording)
    try await capture.start(transport: bee, key: bee.demoToken.key, nonce: nonce, deviceID: bee.deviceID)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(verified)
    #expect(capture.status.stats.packets > 5)
    #expect(capture.status.stats.lostPackets == 0)
    #expect(capture.status.verified)

    // Muting stops the stream.
    try await client.setState(.mute)
    capture.pause()
    let sent = bee.audioPacketsSent
    try await Task.sleep(for: .milliseconds(300))
    #expect(bee.audioPacketsSent == sent)
    #expect(closed.count == 1)
    #expect(closed[0].frames > 10)
    capture.stop(.disconnected)
    #expect(capture.summary.contains("MTU 498"))
}

@MainActor
@Test func flagsAWrongKey() async throws {
    let bee = SimulatedBee(latency: .milliseconds(2))
    let client = BeeClient(transport: bee)
    let capture = AudioCapture(recorder: AudioRecorder(directory: try temporaryDirectory()))
    capture.undecryptableAfter = 10
    var problem: AudioCapture.Problem?
    capture.onProblem = { problem = $0 }
    let nonce = try await client.openSession(bee.demoToken)
    try await client.setState(.recording)
    try await capture.start(transport: bee, key: Data(repeating: 9, count: 16), nonce: nonce, deviceID: bee.deviceID)
    try await Task.sleep(for: .seconds(2))
    #expect(!capture.status.verified)
    if case .undecryptable = problem {} else { Issue.record("expected undecryptable, got \(String(describing: problem))") }
    capture.stop(.disconnected)
}
