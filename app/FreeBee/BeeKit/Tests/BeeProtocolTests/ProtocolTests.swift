import BeeProtocol
import Foundation
import Testing

// The same cases as mac/tests/test_protocol.py. Response framing captured from our unit
// (firmware 0.6.1); device-id bytes replaced with a dummy.
let dummyID = Data(hex: "0102030405060708")!

func hex(_ text: String) -> Data { Data(hex: text)! }

@Test func encodeIsLittleEndianCommandID() {
    #expect(Frame.encode(.getFirmwareVersion) == Data([0x05, 0xC0]))
    #expect(Frame.encode(.setBrightness, Data([0x01, 0x32])) == Data([0x16, 0xC0, 0x01, 0x32]))
}

@Test func decodeFirmwareResponse() throws {
    let msg = try Frame.decode(hex("008005c0010600"))
    #expect(msg.ok)
    #expect(msg.command == Command.getFirmwareVersion.rawValue)
    let version = try FirmwareVersion(payload: msg.payload)
    #expect(version.description == "0.6.1")
    #expect(version.hardwareRevision == nil)
    #expect(version < FirmwareVersion.newestPublic)
}

@Test func decodeBatteryAndState() throws {
    let battery = try Battery(payload: Frame.decode(hex("00800fc06401")).payload)
    #expect(battery == Battery(percent: 100, charging: true))
    let status = try DeviceStatus(payload: Frame.decode(hex("00800ac00101")).payload)
    #expect(status == DeviceStatus(state: .recording, codec: .aac))
}

@Test func errorResponsesEchoTheCommand() throws {
    let msg = try Frame.decode(hex("03801dc0"))
    #expect(!msg.ok)
    #expect(msg.status == .unknownMessage)
    #expect(msg.name == "UnknownMessage")
    #expect(msg.command == Command.getDSN.rawValue)
}

@Test func keyAcceptedCountsAsOK() throws {
    let msg = try Frame.decode(hex("048018c0"))
    #expect(msg.ok)
    #expect(msg.status == .keyAccepted)
}

@Test func deviceIDMatchesBetweenResponseAndAdvert() throws {
    let msg = try Frame.decode(hex("00800ec0") + dummyID)
    #expect(try DeviceID.format(msg.payload) == "0807060504030201")
    let advert = Advertisement.parse([CompanyID.legacy: dummyID])
    #expect(advert == Advertisement(deviceID: "0807060504030201", hardware: .legacy))
    let ids = try SecureIDs(payload: dummyID + Data([0]))
    #expect(ids.deviceID == "0807060504030201")
    #expect(ids.sealed == false)
}

@Test func frontierAdvert() {
    let advert = Advertisement.parse([CompanyID.frontier: dummyID + Data([1, 4, 1])])
    #expect(advert == Advertisement(deviceID: "0807060504030201", hardware: .frontier, hardwareRevision: 4, bonded: true))
}

@Test func coreBluetoothManufacturerDataCarriesTheCompanyID() {
    // CBAdvertisementDataManufacturerDataKey: LE16 company id first.
    #expect(Advertisement.parse(manufacturerData: hex("eebe") + dummyID)?.deviceID == "0807060504030201")
    #expect(Advertisement.parse(manufacturerData: hex("efbe") + dummyID + Data([1, 3, 0]))?.hardwareRevision == 3)
    #expect(Advertisement.isBeeManufacturerData(hex("efbe00")))
    #expect(!Advertisement.isBeeManufacturerData(hex("4c000215")))
    // A Frontier advert without the format marker is rejected, like the official app does.
    #expect(Advertisement.parse(manufacturerData: hex("efbe") + dummyID + Data([2, 3, 0])) == nil)
}

@Test func events() throws {
    let state = try Frame.decode(hex("03a00101"))
    #expect(state.isEvent)
    #expect(state.command == nil)
    #expect(BeeEvent(state).description == "state: recording (codec aac)")
    #expect(BeeEvent(try Frame.decode(hex("04a064"))).description == "battery: 100%")
    #expect(BeeEvent(try Frame.decode(hex("05a001"))).description == "charging: yes")
    #expect(BeeEvent(try Frame.decode(hex("02a001"))).description == "button: hold")
    #expect(BeeEvent(try Frame.decode(hex("02a000"))).description == "button: release")
    #expect(BeeEvent(try Frame.decode(hex("01a0"))) == .doublePress)
    #expect(BeeEvent(try Frame.decode(hex("03a00201"))) == .state(DeviceStatus(state: .sleepHardwareVAD, codec: .aac)))
}

@Test func sealedTokenLayout() throws {
    let key = Data(0..<16)
    let token = try SealedToken(raw: Data("SKV1".utf8) + dummyID + key + Data(count: 80))
    #expect(token.deviceID == "0807060504030201")
    #expect(token.key == key)
    #expect(token.hasExpectedLength)
    // sha256(bytes(range(16))).hexdigest()[:12], as beekit prints it
    #expect(token.fingerprint == "be45cb2605bf")
    #expect(throws: ProtocolError.notAToken) { try SealedToken(raw: Data("SKV2".utf8) + Data(count: 104)) }
}

@Test func unknownValuesSurvive() throws {
    #expect(DeviceState(rawValue: 9) == .unknown(9))
    #expect(DeviceState(rawValue: 9).rawValue == 9)
    #expect(try DeviceStatus(payload: Data([4])) == DeviceStatus(state: .sleepSoftwareVAD, codec: nil))
    #expect(throws: ProtocolError.self) { try Frame.decode(Data([0x00])) }
}

@Test func firmwareVersionWithHardwareRevision() throws {
    let version = try FirmwareVersion(payload: Data([5, 6, 0, 0, 4]))
    #expect(version.description == "0.6.5")
    #expect(version.hardwareRevision == 4)
    #expect(Hardware(revision: 4) == .frontier)
    #expect(Hardware(revision: 1) == .legacy)
    #expect(FirmwareVersion("0.6.1.0") == FirmwareVersion(major: 0, minor: 6, patch: 1))
}

@Test func frontierBatteryIsMillivolts() throws {
    // 4200 mV, charging (layout from the decompiled app; untested on hardware)
    let battery = try Battery(payload: Data([0x68, 0x10, 0x01]), hardware: .frontier)
    #expect(battery.millivolts == 4200)
    #expect(battery.percent == 100)
    #expect(battery.charging)
    #expect(Battery.estimatePercent(millivolts: 3000) == 0)
    #expect(Battery.estimatePercent(millivolts: 3840) == 50)
    #expect(BatteryLevel(eventPayload: Data([0x00, 0x0F]), hardware: .frontier)?.millivolts == 3840)
}

@Test func dsnTrimsPadding() {
    #expect(DSN.parse(Data("G0123".utf8) + Data([0, 0xFF, 0xFF])) == "G0123")
}

@Test func hexRoundTrip() {
    #expect(Data(hex: "0x00 ff:10")! == Data([0x00, 0xFF, 0x10]))
    #expect(Data([0xAB, 0x01]).hex == "ab01")
    #expect(Data(hex: "abc") == nil)
    #expect(Data(hex: "zz") == nil)
}
