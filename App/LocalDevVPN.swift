import Darwin
import Foundation
import UIKit

enum LocalDevVPN {
    static let defaultAddress = "10.7.0.1"
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let enableURL = URL(string: "localdevvpn://enable?scheme=paopaolocation")!

    static var isInstalled: Bool {
        guard let detectURL = URL(string: "localdevvpn://") else { return false }
        return UIApplication.shared.canOpenURL(detectURL)
    }

    static var isConnected: Bool {
        let addresses = ipv4Addresses()
        if addresses.contains(defaultAddress) { return true }
        return addresses.contains { $0.hasPrefix("10.7.0.") }
    }

    static func openOrInstall() {
        let url = isInstalled ? enableURL : appStoreURL
        UIApplication.shared.open(url)
    }

    private static func ipv4Addresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    addresses.append(String(cString: host))
                }
            }
            cursor = interface.ifa_next
        }
        return addresses
    }
}
