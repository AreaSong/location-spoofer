import Foundation

enum SpotActivityStatus: String, Equatable {
    case verifying
    case locating
    case needsSwitch
    case switching
    case stopping
    case notApplied
    case stopped
    case actionFailed
}

struct SpotActivitySnapshot: Equatable {
    var status: SpotActivityStatus
    var placeName: String
    var statusText: String
    var symbolName: String
    var isWarning: Bool
    var caption: String
    var errorText: String
    var primaryAction: String
    var primaryTitle: String
    var secondaryAction: String
    var secondaryTitle: String
    var tertiaryAction: String
    var tertiaryTitle: String
    var retryCommand: String
}

enum SpotActivitySync {
    static let spotActions: Set<String> = ["switchHere", "stopSpoof", "retry", "openApp", "switchFavorite"]
    static let fallbackPlaceName = "当前选点"
    static let locatingStaleInterval: TimeInterval = 120
    static let busyStaleInterval: TimeInterval = 45

    /// 定位中和待切换可以持续很久。只有失败态才用过期时间把岛标成中断。
    static func staleDate(for snapshot: SpotActivitySnapshot, now: Date = Date()) -> Date? {
        switch snapshot.status {
        case .notApplied, .actionFailed:
            return now.addingTimeInterval(locatingStaleInterval)
        case .verifying, .switching, .stopping:
            return now.addingTimeInterval(busyStaleInterval)
        case .locating, .needsSwitch, .stopped:
            return nil
        }
    }

    /// 坐标串在紧凑态会变成「37.7756,...」，岛上改用「当前选点」。
    static func islandPlaceName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallbackPlaceName }
        if looksLikeCoordinatePair(trimmed) { return fallbackPlaceName }
        return trimmed
    }

    static func snapshot(
        isVerifying: Bool,
        isActive: Bool,
        needsSwitch: Bool,
        failed: Bool,
        placeName: String,
        coordinateStandard: String,
        accuracyMeters: Int,
        isSwitching: Bool = false,
        isStopping: Bool = false,
        isStopped: Bool = false,
        actionFailed: Bool = false,
        errorText: String = "",
        retryCommand: String = "",
        shortcuts: [(action: String, title: String)] = []
    ) -> SpotActivitySnapshot? {
        let placeName = islandPlaceName(placeName)
        let caption = standardCaption(coordinateStandard, accuracyMeters: accuracyMeters)
        if actionFailed {
            return spot(
                .actionFailed,
                placeName: placeName,
                statusText: "操作失败",
                symbolName: "exclamationmark.triangle.fill",
                isWarning: true,
                caption: caption,
                errorText: errorText,
                buttons: IslandButtonTriple(
                    primaryAction: "retry",
                    primaryTitle: "重试",
                    secondaryAction: "openApp",
                    secondaryTitle: "打开 App"
                ),
                retryCommand: retryCommand
            )
        }
        if isVerifying && isStopping {
            return spot(
                .stopping,
                placeName: placeName,
                statusText: "正在停止",
                symbolName: "location.slash",
                isWarning: false,
                caption: caption
            )
        }
        if isVerifying && isSwitching {
            return spot(
                .switching,
                placeName: placeName,
                statusText: "切换中",
                symbolName: "arrow.triangle.2.circlepath",
                isWarning: false,
                caption: caption
            )
        }
        if isVerifying {
            return spot(
                .verifying,
                placeName: placeName,
                statusText: "验证中",
                symbolName: "location",
                isWarning: false,
                caption: caption
            )
        }
        if isStopped {
            return spot(
                .stopped,
                placeName: placeName,
                statusText: "已停止",
                symbolName: "checkmark",
                isWarning: false
            )
        }
        if isActive && needsSwitch {
            return spot(
                .needsSwitch,
                placeName: placeName,
                statusText: "待切换",
                symbolName: "arrow.triangle.swap",
                isWarning: false,
                caption: caption,
                buttons: liveButtons(switchHere: true, shortcuts: shortcuts)
            )
        }
        if isActive {
            return spot(
                .locating,
                placeName: placeName,
                statusText: "定位中",
                symbolName: "location.fill",
                isWarning: false,
                caption: caption,
                buttons: liveButtons(switchHere: false, shortcuts: shortcuts)
            )
        }
        if failed {
            return spot(
                .notApplied,
                placeName: placeName,
                statusText: "未生效",
                symbolName: "exclamationmark.triangle.fill",
                isWarning: true,
                caption: caption,
                errorText: errorText,
                buttons: IslandButtonTriple(
                    primaryAction: "retry",
                    primaryTitle: "重试",
                    secondaryAction: "openApp",
                    secondaryTitle: "打开 App"
                ),
                retryCommand: "begin"
            )
        }
        return nil
    }

    static func liveButtons(
        switchHere: Bool,
        shortcuts: [(action: String, title: String)]
    ) -> IslandButtonTriple {
        var items: [(action: String, title: String)] = []
        if switchHere {
            items.append(("switchHere", "切换到此处"))
        }
        items.append(contentsOf: shortcuts.prefix(switchHere ? 1 : 2))
        items.append(("stopSpoof", "停止虚拟定位"))
        return IslandButtonTriple(items: Array(items.prefix(3)))
    }

    /// 定点快照只能带定点动作。路线的暂停、继续、停止路线会被清掉。
    static func normalized(_ snapshot: SpotActivitySnapshot) -> SpotActivitySnapshot {
        var next = snapshot
        let actions = sanitizedActions(
            primary: next.primaryAction,
            primaryTitle: next.primaryTitle,
            secondary: next.secondaryAction,
            secondaryTitle: next.secondaryTitle,
            tertiary: next.tertiaryAction,
            tertiaryTitle: next.tertiaryTitle,
            allowed: spotActions
        )
        next.primaryAction = actions.primary
        next.primaryTitle = actions.primaryTitle
        next.secondaryAction = actions.secondary
        next.secondaryTitle = actions.secondaryTitle
        next.tertiaryAction = actions.tertiary
        next.tertiaryTitle = actions.tertiaryTitle
        if next.primaryAction != "retry" && next.secondaryAction != "retry" && next.tertiaryAction != "retry" {
            next.retryCommand = ""
        }
        if next.status == .verifying || next.status == .switching || next.status == .stopping || next.status == .stopped {
            next.primaryAction = ""
            next.primaryTitle = ""
            next.secondaryAction = ""
            next.secondaryTitle = ""
            next.tertiaryAction = ""
            next.tertiaryTitle = ""
            next.retryCommand = ""
        }
        return next
    }

    static func shouldUpdate(_ previous: SpotActivitySnapshot?, to next: SpotActivitySnapshot) -> Bool {
        previous != next
    }

    private static func standardCaption(_ standard: String, accuracyMeters: Int) -> String {
        let accuracy = "精度 \(accuracyMeters) 米"
        let trimmed = standard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return accuracy }
        return "\(trimmed) · \(accuracy)"
    }

    private static func looksLikeCoordinatePair(_ text: String) -> Bool {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return false
        }
        return true
    }

    private static func spot(
        _ status: SpotActivityStatus,
        placeName: String,
        statusText: String,
        symbolName: String,
        isWarning: Bool,
        caption: String = "",
        errorText: String = "",
        buttons: IslandButtonTriple = .empty,
        retryCommand: String = ""
    ) -> SpotActivitySnapshot {
        SpotActivitySnapshot(
            status: status,
            placeName: placeName,
            statusText: statusText,
            symbolName: symbolName,
            isWarning: isWarning,
            caption: caption,
            errorText: errorText,
            primaryAction: buttons.primaryAction,
            primaryTitle: buttons.primaryTitle,
            secondaryAction: buttons.secondaryAction,
            secondaryTitle: buttons.secondaryTitle,
            tertiaryAction: buttons.tertiaryAction,
            tertiaryTitle: buttons.tertiaryTitle,
            retryCommand: retryCommand
        )
    }
}
