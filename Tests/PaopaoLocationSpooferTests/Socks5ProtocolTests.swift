import XCTest
@testable import PaopaoLocationSpoofer

final class Socks5ProtocolTests: XCTestCase {
    func testGreetingWaitsForMethodsThenReportsLength() {
        XCTAssertEqual(Socks5Protocol.greetingConsumption(in: Data([0x05])), .failure(.incomplete))
        XCTAssertEqual(Socks5Protocol.greetingConsumption(in: Data([0x05, 0x01])), .failure(.incomplete))
        XCTAssertEqual(Socks5Protocol.greetingConsumption(in: Data([0x04, 0x01, 0x00])), .failure(.invalid))
        XCTAssertEqual(Socks5Protocol.greetingConsumption(in: Data([0x05, 0x01, 0x00])), .success(3))
        XCTAssertEqual(Socks5Protocol.methodReply, Data([0x05, 0x00]))
    }

    func testConnectRequestParsesIPv4DomainAndIPv6() throws {
        let ipv4 = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x49, 0x4F])
        let ipv4Target = try Socks5Protocol.request(from: ipv4).get().0
        XCTAssertEqual(ipv4Target, Socks5Protocol.Target(host: "127.0.0.1", port: 18_767))

        let name = Data("example.com".utf8)
        var domain = Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)])
        domain.append(name)
        domain.append(contentsOf: [0x01, 0xBB])
        let domainTarget = try Socks5Protocol.request(from: domain).get().0
        XCTAssertEqual(domainTarget, Socks5Protocol.Target(host: "example.com", port: 443))

        var ipv6 = Data([0x05, 0x01, 0x00, 0x04])
        ipv6.append(Data(repeating: 0, count: 15))
        ipv6.append(1)
        ipv6.append(contentsOf: [0x01, 0xBB])
        let ipv6Target = try Socks5Protocol.request(from: ipv6).get().0
        XCTAssertEqual(ipv6Target.host, "0:0:0:0:0:0:0:1")
        XCTAssertEqual(ipv6Target.port, 443)
    }

    func testConnectRequestRejectsIncompleteBindAndListenAddress() {
        XCTAssertEqual(Socks5Protocol.request(from: Data([0x05, 0x01, 0x00, 0x01])).error, .incomplete)
        XCTAssertEqual(Socks5Protocol.request(from: Data([0x05, 0x02, 0x00, 0x01, 1, 1, 1, 1, 0, 80])).error, .unsupported)
        XCTAssertTrue(
            Socks5Protocol.isListenAddress(Socks5Protocol.Target(host: "127.0.0.1", port: 18_767), port: 18_767)
        )
        XCTAssertFalse(
            Socks5Protocol.isListenAddress(Socks5Protocol.Target(host: "example.com", port: 18_767), port: 18_767)
        )
    }
}

private extension Result {
    var error: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
