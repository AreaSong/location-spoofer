import Darwin
import Foundation

@MainActor
final class ThirdPartyLoopbackProxy: ObservableObject {
    static let shared = ThirdPartyLoopbackProxy()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    private(set) var port: UInt16 = ShadowrocketLoopbackNode.port

    private var acceptSource: DispatchSourceRead?
    private let socketQueue = DispatchQueue(label: "third-party.loopback-proxy", qos: .userInitiated)

    func start(port: UInt16 = ShadowrocketLoopbackNode.port) throws {
        if isRunning, acceptSource != nil, self.port == port { return }
        stop()
        let fd = try LoopbackListen.bind(port: port)
        self.port = port
        lastError = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        source.setEventHandler {
            Socks5POSIXSession.acceptAvailable(from: fd, listenPort: port)
        }
        source.setCancelHandler { Darwin.close(fd) }
        acceptSource = source
        source.resume()
        isRunning = true
        RuntimeLogger.info("APP", "LoopbackProxy", "本机环回代理已启动", details: [
            "地址": "socks5://127.0.0.1:\(port)"
        ])
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        isRunning = false
        lastError = nil
    }
}

enum Socks5POSIXSession {
    static func acceptAvailable(from listenFD: Int32, listenPort: UInt16) {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                return
            }
            LoopbackListen.setBlocking(client)
            DispatchQueue.global(qos: .userInitiated).async {
                run(client, listenPort: listenPort)
            }
        }
    }

    static func run(_ client: Int32, listenPort: UInt16) {
        defer { Darwin.close(client) }
        do {
            let leftover = try handshake(client)
            let target = try readTarget(client, leftover: leftover)
            if Socks5Protocol.isListenAddress(target, port: listenPort) {
                try LoopbackListen.sendAll(client, Socks5Protocol.failedReply)
                return
            }
            let remote = try LoopbackListen.connect(target)
            defer { Darwin.close(remote) }
            try LoopbackListen.sendAll(client, Socks5Protocol.succeededReply)
            relay(client, remote)
        } catch {
            _ = try? LoopbackListen.sendAll(client, Socks5Protocol.failedReply)
        }
    }

    private static func handshake(_ client: Int32) throws -> Data {
        var buffer = Data()
        while true {
            buffer.append(try LoopbackListen.recvSome(client))
            switch Socks5Protocol.greetingConsumption(in: buffer) {
            case .failure(.incomplete):
                continue
            case .success(let consumed):
                try LoopbackListen.sendAll(client, Socks5Protocol.methodReply)
                return Data(buffer.dropFirst(consumed))
            default:
                throw POSIXError(.EBADMSG)
            }
        }
    }

    private static func readTarget(_ client: Int32, leftover: Data) throws -> Socks5Protocol.Target {
        var buffer = leftover
        while buffer.count <= 262 {
            switch Socks5Protocol.request(from: buffer) {
            case .failure(.incomplete):
                buffer.append(try LoopbackListen.recvSome(client))
            case .failure(.unsupported):
                try LoopbackListen.sendAll(client, Socks5Protocol.unsupportedReply)
                throw POSIXError(.EOPNOTSUPP)
            case .failure:
                throw POSIXError(.EBADMSG)
            case .success(let pair):
                return pair.0
            }
        }
        throw POSIXError(.EBADMSG)
    }

    private static func relay(_ left: Int32, _ right: Int32) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            LoopbackListen.copy(left, to: right)
            shutdown(right, SHUT_WR)
            group.leave()
        }
        LoopbackListen.copy(right, to: left)
        shutdown(left, SHUT_WR)
        group.wait()
    }
}

enum LoopbackListen {
    static func bind(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw posixError() }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = ipv4Address("127.0.0.1", port: port)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw posixError()
        }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw posixError()
        }
        return fd
    }

    static func connect(_ target: Socks5Protocol.Target) throws -> Int32 {
        if isIPv4(target.host) {
            return try connectIPv4(target.host, port: target.port)
        }
        if isIPv6(target.host) {
            return try connectIPv6(target.host, port: target.port)
        }
        return try connectHostname(target.host, port: target.port)
    }

    static func sendAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let wrote = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if wrote < 0 && errno == EINTR { continue }
                if wrote <= 0 { throw posixError() }
                sent += wrote
            }
        }
    }

    static func recvSome(_ fd: Int32) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let got = recv(fd, &chunk, chunk.count, 0)
            if got > 0 { return Data(chunk.prefix(got)) }
            if got < 0 && errno == EINTR { continue }
            throw posixError()
        }
    }

    static func copy(_ from: Int32, to: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let got = recv(from, &chunk, chunk.count, 0)
            if got <= 0 { return }
            var sent = 0
            while sent < got {
                let wrote = chunk.withUnsafeBytes { raw in
                    send(to, raw.baseAddress!.advanced(by: sent), got - sent, 0)
                }
                if wrote <= 0 { return }
                sent += wrote
            }
        }
    }

    private static func connectIPv4(_ host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw posixError() }
        var addr = ipv4Address(host, port: port)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw posixError()
        }
        return fd
    }

    private static func connectHostname(_ host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let lookup = host.withCString { hostC in
            String(port).withCString { portC in
                getaddrinfo(hostC, portC, &hints, &result)
            }
        }
        guard lookup == 0, let info = result else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(info) }
        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0, Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                return fd
            }
            if fd >= 0 { Darwin.close(fd) }
            cursor = current.pointee.ai_next
        }
        throw POSIXError(.ECONNREFUSED)
    }

    private static func connectIPv6(_ host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw posixError() }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        let parsed = host.withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }
        guard parsed == 1 else {
            Darwin.close(fd)
            throw POSIXError(.EINVAL)
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw posixError()
        }
        return fd
    }

    static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    private static func isIPv4(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private static func isIPv6(_ host: String) -> Bool {
        var addr = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    private static func ipv4Address(_ host: String, port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        return addr
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
