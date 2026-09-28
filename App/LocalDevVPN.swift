import Darwin
import Foundation
import UIKit

enum LocalDevVPN {
    static let defaultAddress = "10.7.0.1"
    static let addressPrefix = "10.7.0."
    static let commonPeerAddress = "10.7.0.2"
    static let loopbackAddress = "127.0.0.1"
    static let tunnelPort: UInt16 = 49152
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let enableURL = URL(string: "localdevvpn://enable?scheme=paopaolocation")!

    static var isInstalled: Bool {
        guard let detectURL = URL(string: "localdevvpn://") else { return false }
        return UIApplication.shared.canOpenURL(detectURL)
    }

    /// 只说明本机有没有隧道网卡。网卡还在但 RSD 已死时，后续推送会重连。
    static var isConnected: Bool {
        hasTunnelInterface(in: ipv4Addresses())
    }

    static func hasTunnelInterface(in addresses: [String]) -> Bool {
        addresses.contains { $0 == defaultAddress || $0.hasPrefix(addressPrefix) }
    }

    static func openOrInstall() {
        let url = isInstalled ? enableURL : appStoreURL
        UIApplication.shared.open(url)
    }

    /// 推送时按这个顺序试：首选地址、对端、本机网卡、常见对端、回环。
    static func liveTunnelEndpoints(preferred: String) -> [String] {
        tunnelEndpoints(
            preferred: preferred,
            localAddresses: ipv4Addresses(),
            peerAddresses: peerAddresses()
        )
    }

    static func tunnelEndpoints(
        preferred: String,
        localAddresses: [String],
        peerAddresses: [String]
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ ip: String) {
            guard isUsableHost(ip), seen.insert(ip).inserted else { return }
            ordered.append(ip)
        }
        add(preferred)
        peerAddresses.forEach(add)
        localAddresses.forEach(add)
        add(commonPeerAddress)
        add(loopbackAddress)
        return ordered
    }

    static func isUsableHost(_ ip: String) -> Bool {
        if ip == loopbackAddress { return true }
        guard ip.hasPrefix(addressPrefix) else { return false }
        return ip != "\(addressPrefix)0" && ip != "\(addressPrefix)255"
    }

    static func canOpenTunnel(at ip: String, port: UInt16 = tunnelPort, timeoutMilliseconds: Int32 = 250) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return false
        }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS || errno == EALREADY else { return false }
        var pollSocket = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollSocket, 1, timeoutMilliseconds) > 0 else { return false }
        guard pollSocket.revents & Int16(POLLOUT) != 0 else { return false }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.stride)
            let gotError = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0
            return gotError && socketError == 0
    }

    static func ipv4Addresses() -> [String] {
        interfaceIPv4Addresses(includeDestination: false)
    }

    static func peerAddresses() -> [String] {
        interfaceIPv4Addresses(includeDestination: true)
    }

    private static func interfaceIPv4Addresses(includeDestination: Bool) -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            let flags = Int32(bitPattern: interface.ifa_flags)
            if (flags & IFF_UP) != 0 {
                if !includeDestination, let address = interface.ifa_addr, let ip = ipv4String(from: address) {
                    addresses.append(ip)
                }
                if includeDestination, (flags & IFF_POINTOPOINT) != 0,
                   let destination = interface.ifa_dstaddr, let ip = ipv4String(from: destination) {
                    addresses.append(ip)
                }
            }
            cursor = interface.ifa_next
        }
        return addresses
    }

    private static func ipv4String(from pointer: UnsafePointer<sockaddr>) -> String? {
        guard pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            pointer,
            socklen_t(MemoryLayout<sockaddr_in>.size),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: host)
    }
}
