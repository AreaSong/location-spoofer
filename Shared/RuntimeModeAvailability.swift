import Foundation

/// 按系统版本判断每种运行模式的可用程度，模式选择页据此排序和标注。纯函数，可单测。
enum RuntimeModeAvailability {
    enum Status: Equatable {
        case recommended
        case available
        case limited(String)
        case unavailable(String)
    }

    static let minimumTunnelMajorVersion = 18
    static let mitmBlockedMajorVersion = 27

    static let mitmBlockedReason = "iOS 27 起系统禁止拦截定位响应，可能无法使用"
    static let tunnelUnavailableReason = "需要 iOS 18 或更新"

    static func status(for mode: ProxyRuntimeMode, iOSMajor: Int) -> Status {
        switch mode {
        case .developerTunnel:
            return iOSMajor >= minimumTunnelMajorVersion
                ? .recommended
                : .unavailable(tunnelUnavailableReason)
        case .localWiFi, .thirdParty:
            return iOSMajor >= mitmBlockedMajorVersion
                ? .limited(mitmBlockedReason)
                : .available
        }
    }

    /// 推荐的排最前，不可用的排最后；同级保持默认顺序：APP、隧道、第三方。
    static func orderedModes(iOSMajor: Int) -> [ProxyRuntimeMode] {
        let defaultOrder: [ProxyRuntimeMode] = [.localWiFi, .developerTunnel, .thirdParty]
        return defaultOrder
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank(status(for: lhs.element, iOSMajor: iOSMajor))
                let rhsRank = rank(status(for: rhs.element, iOSMajor: iOSMajor))
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func rank(_ status: Status) -> Int {
        switch status {
        case .recommended: return 0
        case .available: return 1
        case .limited: return 2
        case .unavailable: return 3
        }
    }
}
