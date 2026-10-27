@testable import BeeKit
import BeeProtocol
import Foundation
import Testing

/// Records writes and lets the test answer them, like a Bee would.
@MainActor
final class FakeLink {
    var writes: [Data] = []
    var channel: ControlChannel!

    init() {
        channel = ControlChannel { [weak self] data in self?.writes.append(data) }
    }

    func waitForWrites(_ count: Int) async {
        while writes.count < count { await Task.yield() }
    }
}

@MainActor
@Test func routesResponsesByEchoedCommand() async throws {
    let link = FakeLink()
    var events: [Message] = []
    link.channel.onEvent = { events.append($0) }

    async let version = link.channel.request(.getFirmwareVersion)
    await link.waitForWrites(1)
    #expect(link.writes[0] == Data([0x05, 0xC0]))
    // An event and a stray response for another command arrive first; neither completes the request.
    link.channel.receive(Data(hex: "04a064")!)
    link.channel.receive(Data(hex: "00800fc06401")!)
    link.channel.receive(Data(hex: "008005c0010600")!)
    #expect(try await version == Data([1, 6, 0]))
    #expect(events.map(\.code) == [EventCode.battery.rawValue])
    #expect(link.channel.unmatched.map(\.command) == [Command.getBattery.rawValue])
}

@MainActor
@Test func rejectedStatusThrows() async throws {
    let link = FakeLink()
    async let dsn = link.channel.request(.getDSN)
    await link.waitForWrites(1)
    link.channel.receive(Data(hex: "03801dc0")!)
    do {
        _ = try await dsn
        Issue.record("expected UnknownMessage")
    } catch let error as BeeError {
        #expect(error.isUnknownMessage)
    }
}

@MainActor
@Test func oneRequestInFlightAtATime() async throws {
    let link = FakeLink()
    async let first = link.channel.request(.getBattery)
    async let second = link.channel.request(.getDeviceState)
    await link.waitForWrites(1)
    for _ in 0..<20 { await Task.yield() }
    #expect(link.writes.count == 1)  // the second waits for the first's response

    let firstCommand = link.writes[0]
    let answerFirst = firstCommand == Frame.encode(.getBattery) ? "00800fc05000" : "00800ac00001"
    link.channel.receive(Data(hex: answerFirst)!)
    await link.waitForWrites(2)
    let answerSecond = firstCommand == Frame.encode(.getBattery) ? "00800ac00001" : "00800fc05000"
    link.channel.receive(Data(hex: answerSecond)!)
    #expect(try await first == Data([0x50, 0x00]))
    #expect(try await second == Data([0x00, 0x01]))
}

@MainActor
@Test func timesOut() async throws {
    let link = FakeLink()
    await #expect(throws: BeeError.timeout(.getTxLevel)) {
        try await link.channel.request(.getTxLevel, timeout: .milliseconds(50))
    }
}

@MainActor
@Test func closeFailsPendingAndLaterRequests() async throws {
    let link = FakeLink()
    let pending = Task { try await link.channel.request(.getBattery) }
    await link.waitForWrites(1)
    link.channel.close()
    await #expect(throws: BeeError.disconnected) { try await pending.value }
    await #expect(throws: BeeError.disconnected) { try await link.channel.request(.getBattery) }
}

@MainActor
@Test func writeFailureFailsTheRequest() async throws {
    struct Boom: Error {}
    let channel = ControlChannel { _ in throw Boom() }
    await #expect(throws: Boom.self) { try await channel.request(.getBattery) }
}
