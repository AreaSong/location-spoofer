import Foundation

enum ThirdPartyCoordinateCleanupState: String {
    case none
    case possibleCoordinates
    case legacyUnverified
}

/// 只记录坐标副作用的证据，不把配置完成、查询失败或清理失败算作一次写入。
struct ThirdPartyCoordinateCleanup {
    private let defaults: UserDefaults
    private static let stateKey = "thirdPartyCoordinateCleanupState"
    private static let legacyKey = "thirdPartyPendingCoordinateCleanup"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard defaults.object(forKey: Self.stateKey) == nil else { return }
        let needsLegacyReview: Bool
        if defaults.object(forKey: Self.legacyKey) != nil {
            needsLegacyReview = defaults.bool(forKey: Self.legacyKey)
        } else {
            // 更早的版本没有清理键。首次升级时保留其历史不确定性；新安装先写 none，
            // 后续完成配置不会重新触发这条兼容分支。
            needsLegacyReview = defaults.bool(forKey: "thirdPartyRuntimeModeInitialized")
        }
        record(needsLegacyReview ? .legacyUnverified : .none)
    }

    var state: ThirdPartyCoordinateCleanupState {
        if let raw = defaults.string(forKey: Self.stateKey) {
            return ThirdPartyCoordinateCleanupState(rawValue: raw) ?? .legacyUnverified
        }
        // 旧版把真实写入和清理失败混在同一个标记中，不能据此宣称有坐标，也不能自动抹掉。
        return defaults.bool(forKey: Self.legacyKey) ? .legacyUnverified : .none
    }

    func record(_ state: ThirdPartyCoordinateCleanupState) {
        defaults.set(state.rawValue, forKey: Self.stateKey)
        // 保留旧键供回退版本读取；新逻辑始终以带来源含义的新状态为准。
        defaults.set(state != .none, forKey: Self.legacyKey)
    }

    func confirmUnusedLegacyRecord() {
        guard state == .legacyUnverified else { return }
        record(.none)
    }
}
