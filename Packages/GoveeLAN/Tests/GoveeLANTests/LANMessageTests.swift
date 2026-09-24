import XCTest
@testable import GoveeLAN

final class LANMessageTests: XCTestCase {

    private func json(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    func testScanRequestMatchesTheGoveeWireFormat() throws {
        let data = try LANMessage.scanRequest()
        XCTAssertEqual(json(data), #"{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}"#)
    }

    func testDevStatusRequestMatchesTheGoveeWireFormat() throws {
        let data = try LANMessage.devStatusRequest()
        XCTAssertEqual(json(data), #"{"msg":{"cmd":"devStatus","data":{}}}"#)
    }

    func testTurnOnAndOffMatchTheGoveeWireFormat() throws {
        XCTAssertEqual(json(try LANMessage.turn(on: true)),
                       #"{"msg":{"cmd":"turn","data":{"value":1}}}"#)
        XCTAssertEqual(json(try LANMessage.turn(on: false)),
                       #"{"msg":{"cmd":"turn","data":{"value":0}}}"#)
    }

    func testBrightnessMatchesTheGoveeWireFormatAndClampsToZeroThroughOneHundred() throws {
        XCTAssertEqual(json(try LANMessage.brightness(60)),
                       #"{"msg":{"cmd":"brightness","data":{"value":60}}}"#)
        XCTAssertEqual(json(try LANMessage.brightness(255)),
                       #"{"msg":{"cmd":"brightness","data":{"value":100}}}"#)
        XCTAssertEqual(json(try LANMessage.brightness(-7)),
                       #"{"msg":{"cmd":"brightness","data":{"value":0}}}"#)
    }

    func testColorwcWithRGBMatchesTheGoveeWireFormat() throws {
        let data = try LANMessage.colorwc(rgb: GoveeRGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(json(data),
                       #"{"msg":{"cmd":"colorwc","data":{"color":{"b":0,"g":0,"r":255},"colorTemInKelvin":0}}}"#)
    }

    func testColorwcWithKelvinSendsZeroedColorAndTheKelvinValue() throws {
        let data = try LANMessage.colorwc(kelvin: 4000)
        XCTAssertEqual(json(data),
                       #"{"msg":{"cmd":"colorwc","data":{"color":{"b":0,"g":0,"r":0},"colorTemInKelvin":4000}}}"#)
    }

    func testEncodedKeyOrderIsStableAcrossCalls() throws {
        let first = json(try LANMessage.colorwc(rgb: GoveeRGB(r: 255, g: 80, b: 0)))
        XCTAssertEqual(first,
                       #"{"msg":{"cmd":"colorwc","data":{"color":{"b":0,"g":80,"r":255},"colorTemInKelvin":0}}}"#)
        for _ in 0..<20 {
            XCTAssertEqual(json(try LANMessage.colorwc(rgb: GoveeRGB(r: 255, g: 80, b: 0))), first)
        }
    }

    func testDecodeReadsAScanReply() throws {
        let raw = Data(#"""
        {"msg":{"cmd":"scan","data":{"ip":"192.168.0.58","device":"AA:BB:CC:DD:EE:FF:00:22","sku":"H6004","bleVersionHard":"3.01.01","bleVersionSoft":"1.03.01","wifiVersionHard":"1.00.10","wifiVersionSoft":"1.01.27"}}}
        """#.utf8)
        guard case .scan(let reply)? = LANMessage.decode(raw) else {
            return XCTFail("Expected a scan reply.")
        }
        XCTAssertEqual(reply.ip, "192.168.0.58")
        XCTAssertEqual(reply.device, "AA:BB:CC:DD:EE:FF:00:22")
        XCTAssertEqual(reply.sku, "H6004")
        XCTAssertEqual(reply.wifiVersionSoft, "1.01.27")
    }

    func testDecodeToleratesAScanReplyMissingVersionFields() throws {
        let raw = Data(#"{"msg":{"cmd":"scan","data":{"ip":"10.0.0.4","device":"AA:BB","sku":"H6004"}}}"#.utf8)
        guard case .scan(let reply)? = LANMessage.decode(raw) else {
            return XCTFail("Expected a scan reply.")
        }
        XCTAssertEqual(reply.bleVersionHard, "")
        XCTAssertEqual(reply.wifiVersionSoft, "")
    }

    func testDecodeReadsADevStatusReply() throws {
        let raw = Data(#"""
        {"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":60,"color":{"r":255,"g":10,"b":0},"colorTemInKelvin":0}}}
        """#.utf8)
        guard case .status(let reply)? = LANMessage.decode(raw) else {
            return XCTFail("Expected a status reply.")
        }
        XCTAssertEqual(reply.state, BulbState(isOn: true,
                                              brightness: 60,
                                              color: GoveeRGB(r: 255, g: 10, b: 0),
                                              colorTemperatureKelvin: 0))
    }

    func testDecodeReturnsNilForUnrelatedOrMalformedData() {
        XCTAssertNil(LANMessage.decode(Data("not json".utf8)))
        XCTAssertNil(LANMessage.decode(Data(#"{"msg":{"cmd":"razer","data":{"pt":"uwABsQEK"}}}"#.utf8)))
    }

    func testUnknownBulbStateIsOffAndDark() {
        XCTAssertEqual(BulbState.unknown,
                       BulbState(isOn: false, brightness: 0, color: .black, colorTemperatureKelvin: 0))
    }
}
