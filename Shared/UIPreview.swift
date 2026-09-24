import Foundation

/// 模拟器里的测试模式。引导、设置和地图都能点，路线只在本地播放，不写系统定位。
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
