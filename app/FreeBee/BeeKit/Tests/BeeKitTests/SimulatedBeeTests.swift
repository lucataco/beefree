import BeeKit
import BeeProtocol
import Foundation
import Testing

@MainActor
@Test func clientReadsTheSimulatedBee() async throws {
    let bee = SimulatedBee(latency: .milliseconds(2))
    let client = BeeClient(transport: bee)
    #expect(try await client.firmwareVersion().description == "0.6.1")
    #expect(try await client.battery() == Battery(percent: 82, charging: false))
    #expect(try await client.deviceStatus() == DeviceStatus(state: .recording, codec: .aac))
    #expect(try await client.secureIDs().deviceID == bee.deviceID)
    #expect(try await client.brightness() == 60)
    #expect(try await client.bitrate() == 32000)
    #expect(try await client.txLevel() == 8)
    await #expect(throws: BeeError.self) { try await client.dsn() }
}

@MainActor
@Test func muteOnlySticksInsideASession() async throws {
    let bee = SimulatedBee(latency: .milliseconds(2))
    let client = BeeClient(transport: bee)
    try await client.setState(.mute)
    #expect(try await client.deviceStatus().state == .recording)

    let nonce = try await client.openSession(bee.demoToken)
    #expect(nonce.count == 12)
    try await client.setState(.mute)
    #expect(try await client.deviceStatus().state == .mute)
    #expect(bee.received.suffix(4) == [.setEncryptionKey, .getSessionNonce, .setDeviceState, .getDeviceState])
}

@MainActor
@Test func sleepWorksWithoutASession() async throws {
    let bee = SimulatedBee(latency: .milliseconds(2))
    let client = BeeClient(transport: bee)
    var events: [BeeEvent] = []
    client.onEvent = { events.append($0) }
    try await client.setState(.sleepSoftwareVAD)
    #expect(try await client.deviceStatus().state == .sleepSoftwareVAD)
    #expect(events.contains(.state(DeviceStatus(state: .sleepSoftwareVAD, codec: .aac))))
}

@MainActor
@Test func brightnessIsValidated() async throws {
    let client = BeeClient(transport: SimulatedBee(latency: .milliseconds(2)))
    try await client.setBrightness(35)
    #expect(try await client.brightness() == 35)
    await #expect(throws: BeeError.self) { try await client.setBrightness(101) }
}

@MainActor
@Test func eventsDecodeWithTheClientsHardware() async throws {
    let bee = SimulatedBee(latency: .milliseconds(2))
    let client = BeeClient(transport: bee)
    var events: [BeeEvent] = []
    client.onEvent = { events.append($0) }
    bee.pressDouble()
    bee.setBattery(40)
    bee.setCharging(true)
    #expect(events == [.doublePress, .battery(BatteryLevel(percent: 40)), .charging(true)])
}

@MainActor
@Test func firmwareReportOverSMP() async throws {
    let bee = SimulatedBee(latency: .milliseconds(2))
    let smp = SMPClient(transport: bee)
    try await smp.start()
    let report = await smp.report()
    #expect(report.activeSlot?.version == "0.6.1")
    #expect(report.backupSlot?.version == "0.5.0")
    #expect(report.bootloader.value == "MCUboot")
    #expect(report.parameters.value?.bufferSize == 2475)
    guard case .unsupported = report.appInfo else {
        Issue.record("app info should be ENOTSUP, like ours")
        return
    }
}
