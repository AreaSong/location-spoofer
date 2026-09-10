import Foundation

enum AppModeNetworkRequirement {
    static let title = "APP 模式需要 Wi-Fi"

    static func canUseAppMode(wifiEnabled: Bool) -> Bool {
        wifiEnabled
    }

    static func blockedMessage(wifiEnabled: Bool, cellularEnabled: Bool) -> String? {
        guard !wifiEnabled else { return nil }
        if cellularEnabled {
            return "当前是蜂窝网络。APP 模式只支持 Wi-Fi，请改用第三方代理模式，并保持小火箭开启。"
        }
        return "当前未连接 Wi-Fi。APP 模式需要 Wi-Fi；只有流量时请改用第三方代理模式并保持小火箭开启。"
    }
}
