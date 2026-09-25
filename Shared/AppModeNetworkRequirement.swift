import Foundation

struct AppModeNetworkStatus: Equatable {
    var pathSatisfied: Bool
    var wifiEnabled: Bool
    var cellularEnabled: Bool
}

enum AppModeNetworkRequirement {
    static let title = "APP 模式需要 Wi-Fi"

    /// Wi-Fi 接口可能仍挂在不可用路径上，必须同时要求路径 satisfied。
    static func canUseAppMode(_ status: AppModeNetworkStatus) -> Bool {
        status.pathSatisfied && status.wifiEnabled
    }

    static func blockedMessage(_ status: AppModeNetworkStatus) -> String? {
        guard !canUseAppMode(status) else { return nil }
        if !status.wifiEnabled, status.cellularEnabled {
            return "当前是蜂窝网络。APP 模式只支持 Wi-Fi，请改用第三方代理模式，并保持小火箭开启。"
        }
        if status.wifiEnabled {
            return "当前 Wi-Fi 网络不可用。APP 模式需要可用的 Wi-Fi；没有网络时请改用第三方代理模式并保持小火箭开启。"
        }
        return "当前未连接 Wi-Fi。APP 模式需要 Wi-Fi；只有流量时请改用第三方代理模式并保持小火箭开启。"
    }
}
