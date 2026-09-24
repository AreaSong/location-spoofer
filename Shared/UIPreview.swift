import Foundation

/// 模拟器里的开发者模式。反馈走正常成功路径，但不写入系统定位、证书、代理或隧道，也不记成正常模式已完成引导。
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
