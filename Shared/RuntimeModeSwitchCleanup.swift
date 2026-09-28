import Foundation

/// 切模式前必须先清掉的持久定位。第三方客户端和系统模拟都不跟着 App 内的服务一起停。
enum RuntimeModePersistedLocation: Equatable {
    /// 第三方客户端保存的 WLOC 坐标。模块仍开着时，App 切走后也会继续改写定位响应。
    case thirdPartyWLOC
    /// 开发者隧道写进系统的模拟定位。
    case developerSimulation
}

enum RuntimeModeSwitchCleanup {
    static let thirdPartyClearBestEffortMessage =
        "未能通知第三方客户端清除坐标。请在客户端关掉 WLOC 模块；真实位置若还停在旧点，再开关一次定位服务。"

    /// 切模式前要尝试清掉的持久定位。APP 模式即使不是从第三方切过来，也要清 WLOC，避免模块继续拦截。
    static func required(
        from current: ProxyRuntimeMode,
        to next: ProxyRuntimeMode
    ) -> Set<RuntimeModePersistedLocation> {
        guard current != next else { return [] }
        var required: Set<RuntimeModePersistedLocation> = []
        if current == .thirdParty || next == .localWiFi {
            required.insert(.thirdPartyWLOC)
        }
        if current == .developerTunnel {
            required.insert(.developerSimulation)
        }
        return required
    }

    /// 清不掉就保持原模式。切到开发者隧道时第三方 WLOC 只尽力清除：客户端已坏时不能把人锁在第三方模式里。
    static func mustSucceed(
        from current: ProxyRuntimeMode,
        to next: ProxyRuntimeMode
    ) -> Set<RuntimeModePersistedLocation> {
        var items = required(from: current, to: next)
        if next == .developerTunnel {
            items.remove(.thirdPartyWLOC)
        }
        return items
    }
}
