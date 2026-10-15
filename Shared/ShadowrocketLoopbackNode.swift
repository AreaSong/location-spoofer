import Foundation

/// Shadowrocket 本机直连节点。选中后流量不经远程代理，MITM 与 WLOC 脚本仍可生效。
enum ShadowrocketLoopbackNode {
    static let name = "环回"
    static let configLine = "环回 = direct"
    static let skipProxyLine = "skip-proxy = %APPEND% 127.0.0.1, localhost, ::1"
    static let loopbackV4Rule = "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
    static let loopbackV6Rule = "IP-CIDR6,::1/128,DIRECT,no-resolve"
}
