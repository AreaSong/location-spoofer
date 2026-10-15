import Darwin
import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyLoopbackProxyTests: XCTestCase {
    override func tearDown() async throws {
        ThirdPartyLoopbackProxy.shared.stop()
        try await super.tearDown()
    }

    func testSocks5ConnectRelaysToLocalEcho() async throws {
        let echo = try POSIXEchoServer()
        defer { echo.stop() }
        try ThirdPartyLoopbackProxy.shared.start(port: 19_001)
        let payload = Data("loopback-echo".utf8)
        let targetPort = echo.port
        let received = try await Task.detached {
            try Socks5POSIX.exchange(
                proxyPort: 19_001,
                targetPort: targetPort,
                payload: payload
            )
        }.value
        XCTAssertEqual(received, payload)
    }
}

private final class POSIXEchoServer {
    private let listenFD: Int32
    private(set) var port: UInt16

    init() throws {
        let bound = try LoopbackTCP.listen()
        listenFD = bound.fd
        port = bound.port
        Thread.detachNewThread { [listenFD] in
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 { return }
                Self.echo(client)
            }
        }
    }

    func stop() {
        close(listenFD)
    }

    private static func echo(_ fd: Int32) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { raw in
                    send(fd, raw.baseAddress!.advanced(by: sent), count - sent, 0)
                }
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }
}

private enum Socks5POSIX {
    static func exchange(proxyPort: UInt16, targetPort: UInt16, payload: Data) throws -> Data {
        var lastError: Error = POSIXError(.ETIMEDOUT)
        for _ in 0..<50 {
            do {
                return try once(proxyPort: proxyPort, targetPort: targetPort, payload: payload)
            } catch {
                lastError = error
                usleep(20_000)
            }
        }
        throw lastError
    }

    private static func once(proxyPort: UInt16, targetPort: UInt16, payload: Data) throws -> Data {
        let fd = try LoopbackTCP.connect(port: proxyPort)
        defer { close(fd) }
        try LoopbackTCP.sendAll(fd, Data([0x05, 0x01, 0x00]))
        let method = try LoopbackTCP.recvExact(fd, 2)
        guard method == Data([0x05, 0x00]) else { throw POSIXError(.EBADMSG) }
        var request = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        request.append(contentsOf: [UInt8(targetPort >> 8), UInt8(targetPort & 0xFF)])
        try LoopbackTCP.sendAll(fd, request)
        let reply = try LoopbackTCP.recvExact(fd, 10)
        guard reply.first == 0x05, reply.dropFirst().first == 0x00 else { throw POSIXError(.ECONNREFUSED) }
        try LoopbackTCP.sendAll(fd, payload)
        return try LoopbackTCP.recvExact(fd, payload.count)
    }
}

private enum LoopbackTCP {
    static func listen() throws -> (fd: Int32, port: UInt16) {
        let fd = try openSocket()
        var addr = loopbackAddress(port: 0)
        try bind(fd, &addr)
        guard Darwin.listen(fd, 4) == 0 else { throw posixError(close: fd) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookedUp = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard lookedUp == 0 else { throw posixError(close: fd) }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    static func connect(port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        var addr = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw posixError(close: fd) }
        return fd
    }

    static func sendAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let wrote = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if wrote <= 0 { throw posixError(close: nil) }
                sent += wrote
            }
        }
    }

    static func recvExact(_ fd: Int32, _ count: Int) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: count)
        while buffer.count < count {
            let got = recv(fd, &chunk, count - buffer.count, 0)
            if got <= 0 { throw posixError(close: nil) }
            buffer.append(contentsOf: chunk.prefix(got))
        }
        return buffer
    }

    private static func openSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw posixError(close: nil) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        return fd
    }

    private static func bind(_ fd: Int32, _ addr: inout sockaddr_in) throws {
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw posixError(close: fd) }
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return addr
    }

    private static func posixError(close fd: Int32?) -> POSIXError {
        let code = errno
        if let fd { Darwin.close(fd) }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
