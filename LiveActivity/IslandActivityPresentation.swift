import Foundation

enum IslandFavoriteCommand {
    static let prefix = "switchFavorite:"

    static func action(for id: UUID) -> String {
        prefix + id.uuidString
    }

    static func favoriteID(from action: String) -> UUID? {
        guard action.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(action.dropFirst(prefix.count)))
    }
}

struct IslandButtonTriple: Equatable {
    var primaryAction = ""
    var primaryTitle = ""
    var secondaryAction = ""
    var secondaryTitle = ""
    var tertiaryAction = ""
    var tertiaryTitle = ""

    static let empty = IslandButtonTriple()

    var isEmpty: Bool {
        primaryAction.isEmpty && secondaryAction.isEmpty && tertiaryAction.isEmpty
    }

    init(
        primaryAction: String = "",
        primaryTitle: String = "",
        secondaryAction: String = "",
        secondaryTitle: String = "",
        tertiaryAction: String = "",
        tertiaryTitle: String = ""
    ) {
        self.primaryAction = primaryAction
        self.primaryTitle = primaryTitle
        self.secondaryAction = secondaryAction
        self.secondaryTitle = secondaryTitle
        self.tertiaryAction = tertiaryAction
        self.tertiaryTitle = tertiaryTitle
    }

    init(items: [(action: String, title: String)]) {
        let filled = items.filter { !$0.action.isEmpty }
        self.init(
            primaryAction: filled.count > 0 ? filled[0].action : "",
            primaryTitle: filled.count > 0 ? filled[0].title : "",
            secondaryAction: filled.count > 1 ? filled[1].action : "",
            secondaryTitle: filled.count > 1 ? filled[1].title : "",
            tertiaryAction: filled.count > 2 ? filled[2].action : "",
            tertiaryTitle: filled.count > 2 ? filled[2].title : ""
        )
    }

    var items: [(action: String, title: String)] {
        [
            (primaryAction, primaryTitle),
            (secondaryAction, secondaryTitle),
            (tertiaryAction, tertiaryTitle)
        ].filter { !$0.action.isEmpty }
    }
}

enum IslandStalePresentation {
    /// 过程超时或异常才显示中断。定位中、待切换和走路进行中仍是有效会话。
    static func treatsAsInterrupted(phase: String) -> Bool {
        switch phase {
        case "systemFault", "actionFailed", "retrying", "verifying", "switching", "stopping", "planning":
            return true
        default:
            return false
        }
    }

    static func statusText(phase: String, statusText: String, isStale: Bool) -> String {
        if isStale, treatsAsInterrupted(phase: phase) {
            return "已中断"
        }
        return statusText
    }

    static func usesWarningAppearance(phase: String, isWarning: Bool, isStale: Bool) -> Bool {
        isWarning || (isStale && treatsAsInterrupted(phase: phase))
    }

    static func usesStaleSymbol(phase: String, isStale: Bool) -> Bool {
        isStale && treatsAsInterrupted(phase: phase)
    }
}

enum IslandAccessibility {
    static func compactLabel(title: String, status: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return trimmedStatus }
        if trimmedStatus.isEmpty { return trimmedTitle }
        return "\(trimmedTitle)，\(trimmedStatus)"
    }

    static func expandedLabel(title: String, status: String, detail: String, error: String) -> String {
        [title, status, detail, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    static func buttonHint(action: String) -> String {
        if IslandFavoriteCommand.favoriteID(from: action) != nil {
            return "把虚拟定位切换到这个收藏点"
        }
        switch action {
        case "pause": return "暂停路线行走"
        case "resume": return "继续路线行走"
        case "stopRoute": return "停止路线，不关闭当前虚拟定位"
        case "stopSpoof": return "结束当前虚拟定位"
        case "switchHere": return "把虚拟定位切换到当前选点"
        case "cycleSpeed": return "切换到下一档行走速度"
        case "retry": return "再试一次刚才的操作"
        case "openApp": return "打开 App"
        default: return ""
        }
    }
}

enum IslandActionPresentation {
    /// 过期后，只有异常和过程超时才改成重试。定位中、待切换和走路进行中保留原来的动作。
    static func buttons(
        phase: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        tertiaryAction: String = "",
        tertiaryTitle: String = "",
        isStale: Bool
    ) -> IslandButtonTriple {
        let current = IslandButtonTriple(
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            tertiaryAction: tertiaryAction,
            tertiaryTitle: tertiaryTitle
        )
        if !isStale {
            return current
        }
        switch phase {
        case "finished", "stopped":
            return .empty
        case "userPaused":
            return IslandButtonTriple(
                primaryAction: "resume",
                primaryTitle: "继续",
                secondaryAction: "openApp",
                secondaryTitle: "打开 App"
            )
        default:
            if IslandStalePresentation.treatsAsInterrupted(phase: phase) {
                return IslandButtonTriple(
                    primaryAction: "retry",
                    primaryTitle: "重试",
                    secondaryAction: "openApp",
                    secondaryTitle: "打开 App"
                )
            }
            return current
        }
    }

    /// 没有记下失败命令时，按当前阶段重试，避免进行中的重试落到停止定位。
    static func submittedAction(action: String, phase: String, retryCommand: String) -> String {
        guard action == "retry" else { return action }
        if !retryCommand.isEmpty { return retryCommand }
        switch phase {
        case "playing", "retrying":
            return "play"
        case "needsSwitch":
            return "switchHere"
        case "stopping":
            return "stopSpoof"
        case "locating", "verifying", "switching":
            return "begin"
        default:
            return action
        }
    }
}

enum SpotIslandActions {
    /// 验证、切换、停止过程中和已停止不留按钮，避免重复点击，也不把终态显示成可继续。
    /// 这些过程过期后只给打开 App，避免在扩展里再发起一次定位。
    static let quietPhases: Set<String> = ["verifying", "switching", "stopping", "stopped"]

    static func buttons(
        phase: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        tertiaryAction: String = "",
        tertiaryTitle: String = "",
        isStale: Bool
    ) -> IslandButtonTriple {
        if quietPhases.contains(phase) {
            if !isStale || phase == "stopped" {
                return .empty
            }
            return IslandButtonTriple(primaryAction: "openApp", primaryTitle: "打开 App")
        }
        let presented = IslandActionPresentation.buttons(
            phase: phase,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            tertiaryAction: tertiaryAction,
            tertiaryTitle: tertiaryTitle,
            isStale: isStale
        )
        guard phase == "locating" else { return presented }
        return withoutSwitchHere(presented)
    }

    /// 定位中去掉「切换到此处」，收藏快捷方式仍保留。
    private static func withoutSwitchHere(_ buttons: IslandButtonTriple) -> IslandButtonTriple {
        IslandButtonTriple(items: buttons.items.filter { $0.action != "switchHere" })
    }
}

enum RouteIslandLayout {
    static func metricText(
        phase: String,
        detailText: String,
        distanceText: String,
        timeText: String,
        statusText: String,
        speedText: String = ""
    ) -> String {
        let metric: String
        if !detailText.isEmpty {
            metric = detailText
        } else if !distanceText.isEmpty, !timeText.isEmpty {
            metric = "还剩 \(distanceText) · \(timeText)"
        } else if !distanceText.isEmpty {
            metric = "还剩 \(distanceText)"
        } else if !timeText.isEmpty {
            metric = "还剩 \(timeText)"
        } else {
            switch phase {
            case "planning":
                metric = "正在规划路线"
            case "finished":
                metric = "已走完"
            case "stopped":
                metric = "定位仍保持"
            case "retrying":
                metric = "正在重试"
            case "userPaused":
                metric = "已暂停"
            case "playing":
                metric = "正在计算剩余路程"
            default:
                metric = statusText.isEmpty ? "暂时无法估算剩余路程" : statusText
            }
        }
        return appendingSpeed(metric, speedText: speedText, distanceText: distanceText, timeText: timeText)
    }

    static func compactTrailing(phase: String, timeText: String, statusText: String, isStale: Bool) -> String {
        if isStale, IslandStalePresentation.treatsAsInterrupted(phase: phase) {
            return "已中断"
        }
        if !timeText.isEmpty { return timeText }
        if !statusText.isEmpty { return statusText }
        return "路线"
    }

    static func compactUsesProgressRing(phase: String, showsProgress: Bool, isStale: Bool) -> Bool {
        if isStale, IslandStalePresentation.treatsAsInterrupted(phase: phase) {
            return false
        }
        return showsProgress
    }

    static func compactSymbol(phase: String, modeSymbolName: String, symbolName: String, isStale: Bool) -> String {
        if IslandStalePresentation.usesStaleSymbol(phase: phase, isStale: isStale) {
            return "exclamationmark.triangle.fill"
        }
        if !modeSymbolName.isEmpty { return modeSymbolName }
        return symbolName.isEmpty ? "figure.walk" : symbolName
    }

    private static func appendingSpeed(
        _ metric: String,
        speedText: String,
        distanceText: String,
        timeText: String
    ) -> String {
        let speed = speedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speed.isEmpty, !metric.contains(speed) else { return metric }
        if distanceText.isEmpty && timeText.isEmpty { return metric }
        return "\(metric) · \(speed)"
    }
}

enum RouteIslandActions {
    static let quietPhases: Set<String> = ["planning", "retrying", "finished", "stopped"]

    static func buttons(
        phase: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        tertiaryAction: String = "",
        tertiaryTitle: String = "",
        isStale: Bool
    ) -> IslandButtonTriple {
        if quietPhases.contains(phase) {
            if !isStale || phase == "finished" || phase == "stopped" {
                return .empty
            }
            if phase == "planning" {
                return IslandButtonTriple(primaryAction: "openApp", primaryTitle: "打开 App")
            }
        }
        let presented = IslandActionPresentation.buttons(
            phase: phase,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            tertiaryAction: tertiaryAction,
            tertiaryTitle: tertiaryTitle,
            isStale: isStale
        )
        return allowed(presented, phase: phase, isStale: isStale)
    }

    private static func allowed(
        _ buttons: IslandButtonTriple,
        phase: String,
        isStale: Bool
    ) -> IslandButtonTriple {
        let filtered = buttons.items.compactMap { item -> (action: String, title: String)? in
            let next = filter(item.action, title: item.title, phase: phase, isStale: isStale)
            return next.action.isEmpty ? nil : next
        }
        var unique: [(action: String, title: String)] = []
        for item in filtered where !unique.contains(where: { $0.action == item.action }) {
            unique.append(item)
        }
        return IslandButtonTriple(items: unique)
    }

    private static func filter(
        _ action: String,
        title: String,
        phase: String,
        isStale: Bool
    ) -> (action: String, title: String) {
        switch action {
        case "pause":
            if phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            if isStale, IslandStalePresentation.treatsAsInterrupted(phase: phase) { return ("", "") }
            return (action, title.isEmpty ? "暂停" : title)
        case "resume":
            if phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            if isStale, phase != "userPaused" { return ("", "") }
            return (action, "继续")
        case "stopRoute":
            if phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            if isStale, IslandStalePresentation.treatsAsInterrupted(phase: phase) { return ("", "") }
            return (action, "停止路线")
        case "cycleSpeed":
            if phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            if isStale, IslandStalePresentation.treatsAsInterrupted(phase: phase) { return ("", "") }
            if phase != "playing", phase != "userPaused" { return ("", "") }
            return (action, title.isEmpty ? "调速" : title)
        case "retry", "openApp":
            return (action, title)
        default:
            return ("", "")
        }
    }
}
