import Foundation

enum RouteActivityPhaseKey: String, Equatable {
    case playing
    case userPaused
    case systemFault
    case retrying
    case finished
    case stopped
    case actionFailed
}

struct RouteActivitySnapshot: Equatable {
    var phaseKey: RouteActivityPhaseKey
    var statusText: String
    var remainingMinutes: Int
    var routeName: String
    var progress: Double
    var distanceText: String
    var timeText: String
    var symbolName: String
    var isWarning: Bool
    var errorText: String
    var primaryAction: String
    var primaryTitle: String
    var secondaryAction: String
    var secondaryTitle: String
    var retryCommand: String
}

struct RouteCommandTracking: Equatable {
    var isRetrying = false
    var commandFailed = false
    var failedCommand = ""
    var errorText = ""

    static let idle = RouteCommandTracking()

    static func afterAttempt(
        command: String,
        phase: RoutePhase,
        interruption: RouteInterruption,
        waitingForActivation: Bool,
        statusMessage: String
    ) -> RouteCommandTracking {
        switch command {
        case "pause":
            guard phase == .paused, interruption == .userPaused else {
                return failed("pause", "暂停没有执行。")
            }
            return idle
        case "stopRoute":
            guard phase == .preparing, statusMessage == RouteActivitySync.stoppedMessage else {
                return failed("stopRoute", "停止路线没有执行。")
            }
            return idle
        case "play", "resume":
            if phase == .playing { return idle }
            if waitingForActivation { return RouteCommandTracking(isRetrying: true) }
            if interruption == .activationFailed || interruption == .pushFailed { return idle }
            return failed(command, "重试没有执行。")
        default:
            return idle
        }
    }

    func reconcile(
        phase: RoutePhase,
        interruption: RouteInterruption,
        waitingForActivation: Bool
    ) -> RouteCommandTracking {
        var next = self
        if next.isRetrying {
            let settled = phase == .playing
                || interruption == .activationFailed
                || interruption == .pushFailed
                || (!waitingForActivation && phase != .preparing && phase != .paused)
            if settled { next.isRetrying = false }
        }
        if next.commandFailed, phase == .playing || interruption == .activationFailed {
            next.commandFailed = false
            next.failedCommand = ""
            next.errorText = ""
        }
        return next
    }

    private static func failed(_ command: String, _ message: String) -> RouteCommandTracking {
        RouteCommandTracking(commandFailed: true, failedCommand: command, errorText: message)
    }
}

enum RouteActivitySync {
    static let routeActions: Set<String> = ["pause", "resume", "stopRoute", "retry", "openApp"]
    static let userPauseMessage = "已暂停。"
    static let stoppedMessage = "路线已停止，定位仍保持。"
    static let locationBlockedMessage = "当前不能继续定位。"
    static let playingStaleInterval: TimeInterval = 45
    static let failureStaleInterval: TimeInterval = 120

    static func staleDate(for snapshot: RouteActivitySnapshot, now: Date = Date()) -> Date? {
        switch snapshot.phaseKey {
        case .playing, .retrying:
            return now.addingTimeInterval(playingStaleInterval)
        case .systemFault, .actionFailed:
            return now.addingTimeInterval(failureStaleInterval)
        case .userPaused, .finished, .stopped:
            return nil
        }
    }

    static func snapshot(
        phase: RoutePhase,
        interruption: RouteInterruption = .playing,
        statusMessage: String,
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        symbolName: String,
        isRetrying: Bool = false,
        commandFailed: Bool = false,
        failedCommand: String = "",
        confirmStopped: Bool = false
    ) -> RouteActivitySnapshot? {
        if commandFailed {
            return failedCommandSnapshot(
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress,
                statusMessage: statusMessage,
                failedCommand: failedCommand
            )
        }
        if isRetrying {
            return retrying(
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress,
                symbolName: symbolName
            )
        }
        switch phase {
        case .inactive:
            return nil
        case .preparing:
            if interruption == .activationFailed {
                return systemFault(
                    routeName: routeName,
                    remainingMeters: remainingMeters,
                    speedMetersPerSecond: speedMetersPerSecond,
                    progress: progress,
                    errorText: statusMessage,
                    retryCommand: "play"
                )
            }
            if confirmStopped, statusMessage == stoppedMessage {
                return stopped(routeName: routeName, progress: progress)
            }
            return nil
        case .playing:
            return playing(
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress,
                symbolName: symbolName
            )
        case .paused:
            return paused(
                interruption: interruption,
                statusMessage: statusMessage,
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress
            )
        case .finished:
            return finished(routeName: routeName, symbolName: symbolName)
        }
    }

    /// 路线快照只能带路线动作。冲突或跨布局动作会被清掉，避免暂停和停止虚拟定位同时出现。
    static func normalized(_ snapshot: RouteActivitySnapshot) -> RouteActivitySnapshot {
        var next = snapshot
        next.progress = min(max(next.progress, 0), 1)
        let actions = sanitizedActions(
            primary: next.primaryAction,
            primaryTitle: next.primaryTitle,
            secondary: next.secondaryAction,
            secondaryTitle: next.secondaryTitle,
            allowed: routeActions
        )
        next.primaryAction = actions.primary
        next.primaryTitle = actions.primaryTitle
        next.secondaryAction = actions.secondary
        next.secondaryTitle = actions.secondaryTitle
        if next.primaryAction != "retry" && next.secondaryAction != "retry" {
            next.retryCommand = ""
        }
        if next.phaseKey == .finished || next.phaseKey == .stopped || next.phaseKey == .retrying {
            next.primaryAction = ""
            next.primaryTitle = ""
            next.secondaryAction = ""
            next.secondaryTitle = ""
            next.retryCommand = ""
        }
        return next
    }

    /// 进度不到 1% 时不推送，避免每个定位点都打满灵动岛更新额度。
    static let minimumProgressDelta = 0.01

    static func shouldUpdate(_ previous: RouteActivitySnapshot?, to next: RouteActivitySnapshot) -> Bool {
        guard let previous else { return true }
        if previous.phaseKey != next.phaseKey
            || previous.statusText != next.statusText
            || previous.routeName != next.routeName
            || previous.symbolName != next.symbolName
            || previous.isWarning != next.isWarning
            || previous.errorText != next.errorText
            || previous.primaryAction != next.primaryAction
            || previous.primaryTitle != next.primaryTitle
            || previous.secondaryAction != next.secondaryAction
            || previous.secondaryTitle != next.secondaryTitle
            || previous.retryCommand != next.retryCommand
            || previous.distanceText != next.distanceText
            || previous.timeText != next.timeText {
            return true
        }
        return abs(previous.progress - next.progress) >= minimumProgressDelta
    }

    static func remainingMinutes(meters: Double, speedMetersPerSecond: Double) -> Int {
        let seconds = max(meters / max(speedMetersPerSecond, 0.1), 0)
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    private static func playing(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        symbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .playing,
            statusText: "进行中",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: symbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "pause",
            primaryTitle: "暂停",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            retryCommand: ""
        )
    }

    private static func paused(
        interruption: RouteInterruption,
        statusMessage: String,
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        let userPaused = interruption == .userPaused
            || statusMessage == userPauseMessage
            || statusMessage.isEmpty
        let fault = interruption == .pushFailed || (!userPaused && !statusMessage.isEmpty)
        if fault && interruption != .userPaused && statusMessage != userPauseMessage {
            return systemFault(
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress,
                errorText: statusMessage,
                retryCommand: "resume"
            )
        }
        return routeSnapshot(
            phaseKey: .userPaused,
            statusText: "已暂停",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: "pause.fill",
            isWarning: false,
            errorText: "",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            retryCommand: ""
        )
    }

    private static func systemFault(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        errorText: String,
        retryCommand: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .systemFault,
            statusText: "异常",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: "exclamationmark.triangle.fill",
            isWarning: true,
            errorText: errorText,
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            retryCommand: retryCommand
        )
    }

    private static func retrying(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        symbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .retrying,
            statusText: "重试中",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: symbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            retryCommand: ""
        )
    }

    private static func finished(routeName: String, symbolName: String) -> RouteActivitySnapshot {
        routeSnapshot(
            phaseKey: .finished,
            statusText: "已完成",
            minutes: 0,
            routeName: routeName,
            progress: 1,
            remainingMeters: 0,
            symbolName: symbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            retryCommand: ""
        )
    }

    private static func stopped(routeName: String, progress: Double) -> RouteActivitySnapshot {
        routeSnapshot(
            phaseKey: .stopped,
            statusText: "已停止",
            minutes: 0,
            routeName: routeName,
            progress: progress,
            remainingMeters: 0,
            symbolName: "stop.fill",
            isWarning: false,
            errorText: "",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            retryCommand: ""
        )
    }

    private static func failedCommandSnapshot(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        statusMessage: String,
        failedCommand: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .actionFailed,
            statusText: "操作失败",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: "exclamationmark.triangle.fill",
            isWarning: true,
            errorText: statusMessage,
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            retryCommand: failedCommand
        )
    }

    private static func routeSnapshot(
        phaseKey: RouteActivityPhaseKey,
        statusText: String,
        minutes: Int,
        routeName: String,
        progress: Double,
        remainingMeters: Double,
        symbolName: String,
        isWarning: Bool,
        errorText: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        retryCommand: String
    ) -> RouteActivitySnapshot {
        RouteActivitySnapshot(
            phaseKey: phaseKey,
            statusText: statusText,
            remainingMinutes: minutes,
            routeName: routeName,
            progress: progress,
            distanceText: minutes > 0 ? RoutePlayback.formattedDistance(remainingMeters) : "",
            timeText: minutes > 0 ? "\(minutes)分" : "",
            symbolName: symbolName,
            isWarning: isWarning,
            errorText: errorText,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            retryCommand: retryCommand
        )
    }
}

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
    var retryCommand: String
}

enum SpotActivitySync {
    static let spotActions: Set<String> = ["switchHere", "stopSpoof", "retry", "openApp"]
    static let locatingStaleInterval: TimeInterval = 120
    static let busyStaleInterval: TimeInterval = 45

    static func staleDate(for snapshot: SpotActivitySnapshot, now: Date = Date()) -> Date? {
        switch snapshot.status {
        case .locating, .needsSwitch, .notApplied, .actionFailed:
            return now.addingTimeInterval(locatingStaleInterval)
        case .verifying, .switching, .stopping:
            return now.addingTimeInterval(busyStaleInterval)
        case .stopped:
            return nil
        }
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
        retryCommand: String = ""
    ) -> SpotActivitySnapshot? {
        let caption = standardCaption(coordinateStandard, accuracyMeters: accuracyMeters)
        if actionFailed {
            return spot(.actionFailed, placeName: placeName, statusText: "操作失败", symbolName: "exclamationmark.triangle.fill", isWarning: true, caption: caption, errorText: errorText, primaryAction: "retry", primaryTitle: "重试", secondaryAction: "openApp", secondaryTitle: "打开 App", retryCommand: retryCommand)
        }
        if isVerifying && isStopping {
            return spot(.stopping, placeName: placeName, statusText: "正在停止", symbolName: "location.slash", isWarning: false, caption: caption, errorText: "", primaryAction: "", primaryTitle: "", secondaryAction: "", secondaryTitle: "", retryCommand: "")
        }
        if isVerifying && isSwitching {
            return spot(.switching, placeName: placeName, statusText: "切换中", symbolName: "arrow.triangle.2.circlepath", isWarning: false, caption: caption, errorText: "", primaryAction: "", primaryTitle: "", secondaryAction: "", secondaryTitle: "", retryCommand: "")
        }
        if isVerifying {
            return spot(.verifying, placeName: placeName, statusText: "验证中", symbolName: "location", isWarning: false, caption: caption, errorText: "", primaryAction: "", primaryTitle: "", secondaryAction: "", secondaryTitle: "", retryCommand: "")
        }
        if isStopped {
            return spot(.stopped, placeName: placeName, statusText: "已停止", symbolName: "checkmark", isWarning: false, caption: "", errorText: "", primaryAction: "", primaryTitle: "", secondaryAction: "", secondaryTitle: "", retryCommand: "")
        }
        if isActive && needsSwitch {
            return spot(.needsSwitch, placeName: placeName, statusText: "待切换", symbolName: "arrow.triangle.swap", isWarning: false, caption: caption, errorText: "", primaryAction: "switchHere", primaryTitle: "切换到此处", secondaryAction: "stopSpoof", secondaryTitle: "停止虚拟定位", retryCommand: "")
        }
        if isActive {
            return spot(.locating, placeName: placeName, statusText: "定位中", symbolName: "location.fill", isWarning: false, caption: caption, errorText: "", primaryAction: "stopSpoof", primaryTitle: "停止虚拟定位", secondaryAction: "", secondaryTitle: "", retryCommand: "")
        }
        if failed {
            return spot(.notApplied, placeName: placeName, statusText: "未生效", symbolName: "exclamationmark.triangle.fill", isWarning: true, caption: caption, errorText: errorText, primaryAction: "retry", primaryTitle: "重试", secondaryAction: "openApp", secondaryTitle: "打开 App", retryCommand: "begin")
        }
        return nil
    }

    /// 定点快照只能带定点动作。路线的暂停、继续、停止路线会被清掉。
    static func normalized(_ snapshot: SpotActivitySnapshot) -> SpotActivitySnapshot {
        var next = snapshot
        let actions = sanitizedActions(
            primary: next.primaryAction,
            primaryTitle: next.primaryTitle,
            secondary: next.secondaryAction,
            secondaryTitle: next.secondaryTitle,
            allowed: spotActions
        )
        next.primaryAction = actions.primary
        next.primaryTitle = actions.primaryTitle
        next.secondaryAction = actions.secondary
        next.secondaryTitle = actions.secondaryTitle
        if next.primaryAction != "retry" && next.secondaryAction != "retry" {
            next.retryCommand = ""
        }
        if next.status == .verifying || next.status == .switching || next.status == .stopping || next.status == .stopped {
            next.primaryAction = ""
            next.primaryTitle = ""
            next.secondaryAction = ""
            next.secondaryTitle = ""
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

    private static func spot(
        _ status: SpotActivityStatus,
        placeName: String,
        statusText: String,
        symbolName: String,
        isWarning: Bool,
        caption: String,
        errorText: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        retryCommand: String
    ) -> SpotActivitySnapshot {
        SpotActivitySnapshot(
            status: status,
            placeName: placeName,
            statusText: statusText,
            symbolName: symbolName,
            isWarning: isWarning,
            caption: caption,
            errorText: errorText,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            retryCommand: retryCommand
        )
    }
}

private func sanitizedActions(
    primary: String,
    primaryTitle: String,
    secondary: String,
    secondaryTitle: String,
    allowed: Set<String>
) -> (primary: String, primaryTitle: String, secondary: String, secondaryTitle: String) {
    var primaryAction = allowed.contains(primary) ? primary : ""
    var primaryText = primaryAction.isEmpty ? "" : primaryTitle
    var secondaryAction = allowed.contains(secondary) ? secondary : ""
    var secondaryText = secondaryAction.isEmpty ? "" : secondaryTitle
    if primaryAction.isEmpty {
        primaryAction = secondaryAction
        primaryText = secondaryText
        secondaryAction = ""
        secondaryText = ""
    }
    if !secondaryAction.isEmpty, secondaryAction == primaryAction || conflicts(primaryAction, secondaryAction) {
        secondaryAction = ""
        secondaryText = ""
    }
    return (primaryAction, primaryText, secondaryAction, secondaryText)
}

private func conflicts(_ primary: String, _ secondary: String) -> Bool {
    let pair = Set([primary, secondary])
    return pair == ["pause", "resume"]
        || pair == ["stopRoute", "stopSpoof"]
        || pair == ["switchHere", "pause"]
        || pair == ["switchHere", "resume"]
        || pair == ["stopSpoof", "pause"]
        || pair == ["stopSpoof", "resume"]
}
