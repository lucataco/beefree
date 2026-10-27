import Foundation

/// What a Bee's manufacturer data says about it.
///
/// Legacy (0xBEEE): 8-byte device id. Frontier (0xBEEF): id + `0x01` format marker + hw rev + bonded flags.
public struct Advertisement: Hashable, Sendable {
    public var deviceID: String
    public var hardware: Hardware
    public var hardwareRevision: Int?
    public var bonded: Bool?

    public init(deviceID: String, hardware: Hardware, hardwareRevision: Int? = nil, bonded: Bool? = nil) {
        self.deviceID = deviceID
        self.hardware = hardware
        self.hardwareRevision = hardwareRevision
        self.bonded = bonded
    }

    /// Manufacturer data keyed by company id, without the company id bytes (bleak's layout).
    public static func parse(_ byCompany: [UInt16: Data]) -> Advertisement? {
        if let data = byCompany[CompanyID.frontier] {
            let b = [UInt8](data)
            if b.count >= 11, b[8] == 1, let id = try? DeviceID.format(data) {
                return Advertisement(deviceID: id, hardware: .frontier, hardwareRevision: Int(b[9]), bonded: b[10] & 1 != 0)
            }
        }
        if let data = byCompany[CompanyID.legacy], let id = try? DeviceID.format(data) {
            return Advertisement(deviceID: id, hardware: .legacy)
        }
        return nil
    }

    /// CoreBluetooth's `CBAdvertisementDataManufacturerDataKey` value: LE16 company id, then the data.
    public static func parse(manufacturerData: Data) -> Advertisement? {
        let b = [UInt8](manufacturerData)
        guard b.count >= 2 else { return nil }
        return parse([b.le16(at: 0): Data(b[2...])])
    }

    /// Company id at the front of CoreBluetooth manufacturer data, if it's one of Bee's.
    public static func isBeeManufacturerData(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 2 else { return false }
        let company = b.le16(at: 0)
        return company == CompanyID.legacy || company == CompanyID.frontier
    }
}
