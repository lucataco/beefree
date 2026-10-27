import BeeProtocol
import Foundation
import Testing

let tokenHex = "534b5631" + "0102030405060708" + "000102030405060708090a0b0c0d0e0f" + String(repeating: "00", count: 80)

@Test func readsBeekitSecretsFile() throws {
    let json = """
    {
      "devices": {
        "0807060504030201": {
          "token_hex": "\(tokenHex)",
          "source": "/Users/me/trace.pklg",
          "saved_at": "2026-10-20T20:17:40-0700"
        }
      }
    }
    """
    let entries = try KeyFile.parse(Data(json.utf8))
    #expect(entries.count == 1)
    #expect(entries[0].deviceID == "0807060504030201")
    #expect(entries[0].token.key == Data(0..<16))
    #expect(entries[0].source == "/Users/me/trace.pklg")
}

@Test func readsAPastedToken() throws {
    let spaced = stride(from: 0, to: tokenHex.count, by: 8).map { i in
        String(tokenHex.dropFirst(i).prefix(8))
    }.joined(separator: " ")
    #expect(try KeyFile.parseHex(spaced).deviceID == "0807060504030201")
    #expect(try KeyFile.parse(Data((tokenHex + "\n").utf8)).count == 1)
}

@Test func rejectsFilesWithoutTokens() {
    #expect(throws: ProtocolError.self) { try KeyFile.parse(Data(#"{"devices": {}}"#.utf8)) }
    #expect(throws: ProtocolError.self) { try KeyFile.parse(Data(#"{"something": 1}"#.utf8)) }
    #expect(throws: ProtocolError.self) { try KeyFile.parse(Data("hello".utf8)) }
    #expect(throws: ProtocolError.notAToken) { try KeyFile.parseHex("00112233" + String(repeating: "00", count: 40)) }
}
