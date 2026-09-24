import Foundation

/// 模拟器里跳过代理、证书和隧道，只打开地图看界面。
enum UIPreview {
    static let storageKey = "uiPreviewEnabled"

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        isAvailable && defaults.bool(forKey: storageKey)
    }

    static func enable(defaults: UserDefaults = .standard) {
        guard isAvailable else { return }
        defaults.set(true, forKey: storageKey)
    }

    static func disable(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: storageKey)
    }
}
