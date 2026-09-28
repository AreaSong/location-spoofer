import Foundation

enum DeveloperTunnelHelp {
    static let overview =
        "定点和路线通过本机隧道写入系统定位。请先连上 LocalDevVPN，并导入配对文件。这台手机必须作为客户端连着 Wi-Fi（无公网也可以，流量可同时开）；只开流量或自己开热点不行。iOS 18 到 26 用电脑生成一次即可。"

    static let connectionChecksTitle = "连不上时检查这些"

    static let connectionChecks = """
    1. LocalDevVPN 显示 Connected。
    2. 这台手机已作为客户端连上 Wi-Fi。家里路由、别人的热点、书包里的发射盒都行，不需要能上公网。只开流量、关掉 Wi-Fi 通常连不上。
    3. 自己开个人热点不算。那是热点主人，系统仍当成没连 Wi-Fi。LocalDevVPN 是另一条虚线路，默认 10.7；家里普通 Wi-Fi 一般不用改 IP。只有已经连着 Wi-Fi 仍失败时，再把 Device / Tunnel IP 改到当前 Wi-Fi 网段。
    4. 仍失败：点「清理隧道会话」，重连 LocalDevVPN，或划掉本 App 再打开。
    """
}

enum RouteLocationReadiness: Equatable, Sendable {
    case ready
    case needsInstall
    case tunnelDisconnected
    case needsPairing

    var blockingMessage: String? {
        switch self {
        case .ready:
            return nil
        case .needsInstall:
            return "路线要系统定位跟着走，请先安装 LocalDevVPN。"
        case .tunnelDisconnected:
            return "请先打开 LocalDevVPN，并连上本机隧道。"
        case .needsPairing:
            return "请导入配对文件。iOS 18 到 26 用电脑生成一次，之后播放不用连电脑。"
        }
    }
}

struct DeveloperTunnelActivity: Equatable {
    var lastSetAt: Date?
    var lastClearAt: Date?
    var lastFailure: RouteLocationPushFailure?
    /// clear 失败后本地句柄已丢掉，系统模拟可能还开着。下次 clear 必须重连。
    var simulationMayStillBeActive = false

    var diagnosticText: String {
        let failure = lastFailure?.message ?? "无"
        return """
        最近 set: \(Self.clockText(lastSetAt))
        最近 clear: \(Self.clockText(lastClearAt))
        失败原因: \(failure)
        """
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func clockText(_ date: Date?) -> String {
        guard let date else { return "无" }
        return clock.string(from: date)
    }
}

struct RouteLocationStatus: Equatable {
    var vpnInstalled: Bool
    var tunnelConnected: Bool
    var hasPairing: Bool

    var readiness: RouteLocationReadiness {
        if !vpnInstalled { return .needsInstall }
        if !tunnelConnected { return .tunnelDisconnected }
        if !hasPairing { return .needsPairing }
        return .ready
    }
}

enum RouteLocationPushFailure: Equatable, Sendable {
    case notReady(RouteLocationReadiness)
    case tunnel
    /// 隧道网卡还在，但当前只有蜂窝：系统不把本机隧道当成可握手的本地地址。
    case tunnelOnCellular
    case pairing
    case rejected
    /// 系统侧 clear 失败。本地句柄还在，模拟定位不能当成已关闭。
    case clearFailed
    /// 这次调用已被更新的 set/clear 或取消取代，调用方不要改界面状态。
    case superseded

    var message: String {
        switch self {
        case .notReady(let readiness):
            return readiness.blockingMessage ?? "路线定位还没准备好。"
        case .tunnel:
            return "连不上本机隧道。请确认这台手机已作为客户端连上 Wi-Fi（自己开热点不算）。只开流量系统不放行。仍失败请清理隧道会话，或划掉本 App 再打开。"
        case .tunnelOnCellular:
            return "当前只开了流量。请作为客户端连上 Wi-Fi（无公网也可以），不要用本机个人热点。"
        case .pairing:
            return "配对文件无效。请重新导入配对文件后再试。"
        case .rejected:
            return "系统定位推送失败，已暂停。"
        case .clearFailed:
            return "系统定位没有关掉，模拟仍在生效。"
        case .superseded:
            return "定位操作已取消。"
        }
    }
}

@MainActor
protocol DeveloperLocationPushing: AnyObject {
    var readiness: RouteLocationReadiness { get }
    func set(latitude: Double, longitude: Double) async -> RouteLocationPushFailure?
    func clear() async -> RouteLocationPushFailure?
}

enum RouteLocationLaunch {
    static let spoofSessionFailureMessage = "坐标写入失败，路线已暂停。"

    /// 开发者隧道：就绪后每个采样都推送。
    @MainActor
    static func prepare(
        _ route: RoutePlaybackController,
        readiness: RouteLocationReadiness
    ) -> String? {
        if let message = readiness.blockingMessage {
            route.statusMessage = message
            return message
        }
        route.ignoresWriteGate = true
        route.pushFailureMessage = RouteLocationPushFailure.rejected.message
        return nil
    }

    /// 本机代理和第三方模式：经代理写入，沿用 8 米 / 5 秒的写入节流。
    @MainActor
    static func prepareForSpoofSession(_ route: RoutePlaybackController) {
        route.ignoresWriteGate = false
        route.pushFailureMessage = spoofSessionFailureMessage
    }
}

enum RouteLocationStop {
    /// 退出路线和走完改为定点接管，不再自动清除系统模拟。
    static func shouldClearSimulation(
        from _: RoutePhase,
        to _: RoutePhase,
        activationWritePending _: Bool = false
    ) -> Bool {
        false
    }

    /// 把已写下的虚拟点交给定点。未写过坐标的准备态退出不接管。
    static func shouldHandoffToSpot(
        from: RoutePhase,
        to: RoutePhase,
        activationWritePending: Bool = false,
        isStoppedKeepingLocation: Bool = false
    ) -> Bool {
        if activationWritePending, to == .inactive { return true }
        switch (from, to) {
        case (.playing, .inactive), (.paused, .inactive),
             (.playing, .finished), (.paused, .finished),
             (.finished, .inactive):
            return true
        case (.preparing, .inactive):
            return isStoppedKeepingLocation
        default:
            return false
        }
    }

    static func keptCoordinate(
        writtenLatitude: Double?,
        writtenLongitude: Double?,
        lastWritten: CoordinatePair?
    ) -> CoordinatePair? {
        if let lastWritten { return lastWritten }
        if let writtenLatitude, let writtenLongitude {
            return CoordinateConverter.coordinatePair(
                lat: writtenLatitude,
                lon: writtenLongitude,
                mapCoordinateSystem: .wgs84
            )
        }
        return nil
    }
}
