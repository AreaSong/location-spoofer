import Foundation

/// 小火箭首页可导入的本机 SOCKS5 节点。选中后流量进 App 环回代理，不经机场。
enum ShadowrocketLoopbackNode {
    static let name = "环回"
    static let host = "127.0.0.1"
    static let port: UInt16 = 18_767
    static let skipProxyLine = "skip-proxy = %APPEND% 127.0.0.1, localhost, ::1"
    static let loopbackV4Rule = "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
    static let loopbackV6Rule = "IP-CIDR6,::1/128,DIRECT,no-resolve"

    static var configLine: String {
        "\(name) = socks5, \(host), \(port)"
    }

    static var importURI: String {
        "socks5://\(host):\(port)#\(name)"
    }

    static var addURL: URL {
        let encoded = importURI.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? importURI
        return URL(string: "shadowrocket://add/\(encoded)")!
    }
}
