import Darwin
import XCTest
@testable import GoveeLAN

final class LANEndpointTests: XCTestCase {

    func testAValidIPv4HostBuildsASocketAddress() throws {
        let endpoint = LANEndpoint(host: "192.168.1.42", port: 4003)
        let address = try XCTUnwrap(endpoint.socketAddress())
        XCTAssertEqual(address.sin_family, sa_family_t(AF_INET))
        XCTAssertEqual(UInt16(bigEndian: address.sin_port), 4003)
        XCTAssertEqual(address.sin_addr.s_addr, inet_addr("192.168.1.42"))
    }

    /// `inet_addr` answers INADDR_NONE for anything malformed, and INADDR_NONE is the
    /// broadcast address, so a bad host used to send this bulb's command to every device
    /// on the network. There is no address to send to now, and the caller skips it.
    func testAMalformedHostHasNoSocketAddress() {
        for host in ["", "not-an-ip", "999.1.1.1", "192.168.1", "192.168.1.1.1", "1.2.3.4 "] {
            XCTAssertNil(LANEndpoint(host: host, port: 4003).socketAddress(),
                         "\(host) must not resolve to an address.")
            XCTAssertFalse(LANEndpoint.isValidIPv4(host), "\(host) must not validate.")
        }
        XCTAssertTrue(LANEndpoint.isValidIPv4("255.255.255.255"))
        XCTAssertTrue(LANEndpoint.isValidIPv4("10.0.0.1"))
    }

    /// The broadcast address is a real address, so it only ever reaches the wire when a
    /// caller asks for it by name, never as the fallout of a typo.
    func testTheBroadcastAddressIsOnlyReachedDeliberately() {
        XCTAssertNil(LANEndpoint(host: "3.x.1.1", port: 4003).socketAddress())
        let broadcast = LANEndpoint(host: "255.255.255.255", port: 4003).socketAddress()
        XCTAssertEqual(broadcast?.sin_addr.s_addr, inet_addr("255.255.255.255"))
    }
}
