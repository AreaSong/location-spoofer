import Foundation

/// 切模式前必须先清掉的持久定位。第三方客户端和系统模拟都不跟着 App 内的服务一起停。
enum RuntimeModePersistedLocation: Equatable {
    /// 第三方客户端保存的 WLOC 坐标。模块仍开着时，App 切走后也会继续改写定位响应。
    case thirdPartyWLOC
    /// 开发者隧道写进系统的模拟定位。
    case developerSimulation
}

/// 仅用于一次清理失败后的恢复，不持久化，也不代表第三方坐标已经清除。
struct ThirdPartyModeSwitchRecovery: Equatable {
    let source: ProxyRuntimeMode
    let destination: ProxyRuntimeMode
    let diagnosis: String
    var isLegacyUnverified = false

    static let title = "切换前请停用第三方代理"
    static let continueTitle = "已停用，继续切换"
    static let unusedLegacyTitle = "从未同步，直接切换"

    var alertTitle: String {
        isLegacyUnverified ? "确认第三方定位使用记录" : Self.title
    }

    var message: String {
        if isLegacyUnverified {
            return "旧版留下了待清理标记，但无法确认是否写入过坐标。\n\n若从未向第三方同步过坐标，可直接切换到\(destination.displayName)并移除旧标记；否则请重试清理，或先停用第三方模块/代理再继续。重新启用第三方代理前仍需清除旧坐标。"
        }
        return "第三方可能仍有未清除的坐标。\(diagnosis)\n\n如需继续切换到\(destination.displayName)，请先在第三方客户端停用 WLOC 模块或关闭代理/VPN。确认停用后可继续切换；以后重新启用第三方代理前，请先清除旧坐标。"
    }

    func applies(from current: ProxyRuntimeMode, to next: ProxyRuntimeMode) -> Bool {
        source == current && destination == next && current != next && next != .thirdParty
    }
}

enum RuntimeModeSwitchCleanup {
    /// APP 和开发者模式使用相同的坐标证据；无写入或已有坐标时不要求第三方清理。
    static func required(
        from current: ProxyRuntimeMode,
        to next: ProxyRuntimeMode,
        thirdPartyNeedsCleanup: Bool = true,
        confirmedThirdPartyDisabled recovery: ThirdPartyModeSwitchRecovery? = nil
    ) -> Set<RuntimeModePersistedLocation> {
        guard current != next else { return [] }
        var required: Set<RuntimeModePersistedLocation> = []
        let thirdPartyDisabled = recovery?.applies(from: current, to: next) == true
        if next != .thirdParty && thirdPartyNeedsCleanup && !thirdPartyDisabled {
            required.insert(.thirdPartyWLOC)
        }
        if current == .developerTunnel {
            required.insert(.developerSimulation)
        }
        return required
    }

    /// 默认清理失败保持原模式；明确确认停用第三方后，只豁免本次第三方清理，系统模拟仍须关闭。
    static func mustSucceed(
        from current: ProxyRuntimeMode,
        to next: ProxyRuntimeMode,
        thirdPartyNeedsCleanup: Bool = true,
        confirmedThirdPartyDisabled recovery: ThirdPartyModeSwitchRecovery? = nil
    ) -> Set<RuntimeModePersistedLocation> {
        required(from: current, to: next, thirdPartyNeedsCleanup: thirdPartyNeedsCleanup,
                 confirmedThirdPartyDisabled: recovery)
    }
}
