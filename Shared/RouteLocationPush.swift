import Foundation

enum RouteLocationReadiness: Equatable {
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

enum RouteLocationPushFailure: Equatable {
    case notReady(RouteLocationReadiness)
    case tunnel
    case pairing
    case rejected

    var message: String {
        switch self {
        case .notReady(let readiness):
            return readiness.blockingMessage ?? "路线定位还没准备好。"
        case .tunnel:
            return "连不上本机隧道，路线已暂停。"
        case .pairing:
            return "配对文件无效，路线已暂停。"
        case .rejected:
            return "系统定位推送失败，已暂停。"
        }
    }
}

@MainActor
protocol DeveloperLocationPushing: AnyObject {
    var readiness: RouteLocationReadiness { get }
    func set(latitude: Double, longitude: Double) async -> RouteLocationPushFailure?
    func clear() async
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
    static func shouldClearSimulation(from: RoutePhase, to: RoutePhase) -> Bool {
        switch (from, to) {
        case (.playing, .inactive), (.paused, .inactive), (.playing, .finished), (.paused, .finished):
            return true
        default:
            return false
        }
    }
}
