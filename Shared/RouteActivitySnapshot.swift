import Foundation

enum RouteActivityPhaseKey: String, Equatable {
    case planning
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
    var modeSymbolName: String
    var isWarning: Bool
    var errorText: String
    var primaryAction: String
    var primaryTitle: String
    var secondaryAction: String
    var secondaryTitle: String
    var tertiaryAction: String
    var tertiaryTitle: String
    var retryCommand: String
    var speedText: String
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
        if next.commandFailed,
           !Self.showsCommandFailure(
               phase: phase,
               interruption: interruption,
               waitingForActivation: waitingForActivation
           ) {
            next.commandFailed = false
            next.failedCommand = ""
            next.errorText = ""
        }
        return next
    }

    /// 只有暂停中的路线，或仍在等待开启的路线，才继续显示动作失败。
    /// 进行中、已结束、未开始和普通准备态都不再占岛，避免过期的暂停盖住定点。
    static func showsCommandFailure(
        phase: RoutePhase,
        interruption: RouteInterruption,
        waitingForActivation: Bool
    ) -> Bool {
        if interruption == .activationFailed { return false }
        switch phase {
        case .paused:
            return true
        case .preparing:
            return waitingForActivation
        case .playing, .inactive, .finished:
            return false
        }
    }

    /// 路线已不能展示失败时返回空跟踪，让定点岛接上。同一条失败不重复写入。
    static func rejectionResult(
        current: RouteCommandTracking,
        action: String,
        message: String,
        phase: RoutePhase,
        interruption: RouteInterruption,
        waitingForActivation: Bool
    ) -> RouteCommandTracking {
        guard showsCommandFailure(
            phase: phase,
            interruption: interruption,
            waitingForActivation: waitingForActivation
        ) else { return .idle }
        let next = RouteCommandTracking(commandFailed: true, failedCommand: action, errorText: message)
        if current == next { return current }
        return next
    }

    /// 这个动作已经生效时，清掉对应失败，避免重试或打开 App 把同一条失败再写回去。
    func clearingSatisfied(_ action: String) -> RouteCommandTracking {
        guard commandFailed, failedCommand == action else { return self }
        return .idle
    }

    private static func failed(_ command: String, _ message: String) -> RouteCommandTracking {
        RouteCommandTracking(commandFailed: true, failedCommand: command, errorText: message)
    }
}

enum RouteActivitySync {
    static let routeActions: Set<String> = ["pause", "resume", "stopRoute", "retry", "openApp", "cycleSpeed"]
    static let userPauseMessage = "已暂停。"
    static let stoppedMessage = "路线已停止，定位仍保持。"
    static let keptLocationDetail = "定位仍保持"
    static let stoppedConfirmInterval: TimeInterval = 3
    static let locationBlockedMessage = "当前不能继续定位。"
    /// 只有重试中这种短暂过程才用短过期。进行中的走路可以持续很久，不能 45 秒就标成中断。
    static let playingStaleInterval: TimeInterval = 45
    static let failureStaleInterval: TimeInterval = 120
    /// 与路线规划时写入的状态文案一致，用来把规划中送上路线岛。
    static let planningMessage = "正在规划沿路路线…"

    /// 停止路线的短确认结束后，定点仍生效就不再占岛，交给定点布局。
    static func suppressStoppedRoute(confirmUntil: Date?, now: Date, spotStillActive: Bool) -> Bool {
        guard spotStillActive, let confirmUntil else { return false }
        return now >= confirmUntil
    }

    static func detailText(for snapshot: RouteActivitySnapshot) -> String {
        let metric: String
        if snapshot.phaseKey == .stopped {
            metric = keptLocationDetail
        } else if !snapshot.distanceText.isEmpty, !snapshot.timeText.isEmpty {
            metric = "还剩 \(snapshot.distanceText) · \(snapshot.timeText)"
        } else if !snapshot.distanceText.isEmpty {
            metric = "还剩 \(snapshot.distanceText)"
        } else if !snapshot.timeText.isEmpty {
            metric = "还剩 \(snapshot.timeText)"
        } else {
            switch snapshot.phaseKey {
            case .planning:
                metric = "正在规划路线"
            case .finished:
                metric = "已走完"
            case .stopped:
                metric = keptLocationDetail
            case .retrying:
                metric = "正在重试"
            case .userPaused:
                metric = "已暂停"
            case .playing:
                metric = "正在计算剩余路程"
            case .systemFault, .actionFailed:
                metric = snapshot.statusText.isEmpty ? "暂时无法估算剩余路程" : snapshot.statusText
            }
        }
        let speed = snapshot.speedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if speed.isEmpty || metric.contains(speed) { return metric }
        if snapshot.distanceText.isEmpty && snapshot.timeText.isEmpty { return metric }
        return "\(metric) · \(speed)"
    }

    static func staleDate(for snapshot: RouteActivitySnapshot, now: Date = Date()) -> Date? {
        switch snapshot.phaseKey {
        case .retrying:
            return now.addingTimeInterval(playingStaleInterval)
        case .systemFault, .actionFailed:
            return now.addingTimeInterval(failureStaleInterval)
        case .playing, .userPaused, .finished, .stopped, .planning:
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
        confirmStopped: Bool = false,
        isPlanning: Bool = false
    ) -> RouteActivitySnapshot? {
        if commandFailed, phase != .inactive, phase != .finished {
            return failedCommandSnapshot(
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress,
                statusMessage: statusMessage,
                failedCommand: failedCommand,
                symbolName: symbolName
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
                    retryCommand: "play",
                    modeSymbolName: symbolName
                )
            }
            if confirmStopped, statusMessage == stoppedMessage {
                return stopped(routeName: routeName, progress: progress, modeSymbolName: symbolName)
            }
            if isPlanning || statusMessage == planningMessage {
                return planning(
                    routeName: routeName,
                    remainingMeters: remainingMeters,
                    speedMetersPerSecond: speedMetersPerSecond,
                    symbolName: symbolName
                )
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
                progress: progress,
                modeSymbolName: symbolName
            )
        case .finished:
            return finished(routeName: routeName, modeSymbolName: symbolName)
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
            tertiary: next.tertiaryAction,
            tertiaryTitle: next.tertiaryTitle,
            allowed: routeActions
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
        if next.phaseKey == .finished || next.phaseKey == .stopped || next.phaseKey == .retrying || next.phaseKey == .planning {
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

    /// 进度不到 1% 时不推送。剩余距离按米变化不算一次更新，分钟、状态和动作变化仍立即推送。
    static let minimumProgressDelta = 0.01

    static func shouldUpdate(_ previous: RouteActivitySnapshot?, to next: RouteActivitySnapshot) -> Bool {
        guard let previous else { return true }
        if previous.phaseKey != next.phaseKey
            || previous.statusText != next.statusText
            || previous.routeName != next.routeName
            || previous.symbolName != next.symbolName
            || previous.modeSymbolName != next.modeSymbolName
            || previous.isWarning != next.isWarning
            || previous.errorText != next.errorText
            || previous.primaryAction != next.primaryAction
            || previous.primaryTitle != next.primaryTitle
            || previous.secondaryAction != next.secondaryAction
            || previous.secondaryTitle != next.secondaryTitle
            || previous.tertiaryAction != next.tertiaryAction
            || previous.tertiaryTitle != next.tertiaryTitle
            || previous.retryCommand != next.retryCommand
            || previous.timeText != next.timeText
            || previous.speedText != next.speedText {
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
            speedMetersPerSecond: speedMetersPerSecond,
            symbolName: symbolName,
            modeSymbolName: symbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "pause",
            primaryTitle: "暂停",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            tertiaryAction: "cycleSpeed",
            tertiaryTitle: speedCycleTitle(speedMetersPerSecond: speedMetersPerSecond),
            retryCommand: "",
            speedText: speedLabel(speedMetersPerSecond: speedMetersPerSecond)
        )
    }

    private static func paused(
        interruption: RouteInterruption,
        statusMessage: String,
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        modeSymbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        let userPaused = interruption == .userPaused || statusMessage == userPauseMessage
        if userPaused {
            return routeSnapshot(
                phaseKey: .userPaused,
                statusText: "已暂停",
                minutes: minutes,
                routeName: routeName,
                progress: progress,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                symbolName: "pause.fill",
                modeSymbolName: modeSymbolName,
                isWarning: false,
                errorText: "",
                primaryAction: "resume",
                primaryTitle: "继续",
                secondaryAction: "stopRoute",
                secondaryTitle: "停止路线",
                tertiaryAction: "cycleSpeed",
                tertiaryTitle: speedCycleTitle(speedMetersPerSecond: speedMetersPerSecond),
                retryCommand: "",
                speedText: speedLabel(speedMetersPerSecond: speedMetersPerSecond)
            )
        }
        return systemFault(
            routeName: routeName,
            remainingMeters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            progress: progress,
            errorText: statusMessage,
            retryCommand: "resume",
            modeSymbolName: modeSymbolName
        )
    }

    private static func systemFault(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        errorText: String,
        retryCommand: String,
        modeSymbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .systemFault,
            statusText: "异常",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            symbolName: "exclamationmark.triangle.fill",
            modeSymbolName: modeSymbolName,
            isWarning: true,
            errorText: errorText,
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            retryCommand: retryCommand
        )
    }

    private static func planning(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        symbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMeters > 0
            ? remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
            : 0
        return routeSnapshot(
            phaseKey: .planning,
            statusText: "规划中",
            minutes: minutes,
            routeName: routeName,
            progress: 0,
            remainingMeters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            symbolName: symbolName,
            modeSymbolName: symbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            retryCommand: ""
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
            speedMetersPerSecond: speedMetersPerSecond,
            symbolName: symbolName,
            modeSymbolName: symbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            retryCommand: ""
        )
    }

    private static func finished(routeName: String, modeSymbolName: String) -> RouteActivitySnapshot {
        routeSnapshot(
            phaseKey: .finished,
            statusText: "已完成",
            minutes: 0,
            routeName: routeName,
            progress: 1,
            remainingMeters: 0,
            symbolName: "checkmark",
            modeSymbolName: modeSymbolName,
            isWarning: false,
            errorText: "",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            retryCommand: ""
        )
    }

    private static func stopped(routeName: String, progress: Double, modeSymbolName: String) -> RouteActivitySnapshot {
        routeSnapshot(
            phaseKey: .stopped,
            statusText: "已停止",
            minutes: 0,
            routeName: routeName,
            progress: progress,
            remainingMeters: 0,
            symbolName: "stop.fill",
            modeSymbolName: modeSymbolName,
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
        failedCommand: String,
        symbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .actionFailed,
            statusText: "操作失败",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond,
            symbolName: "exclamationmark.triangle.fill",
            modeSymbolName: symbolName,
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
        speedMetersPerSecond: Double = 0,
        symbolName: String,
        modeSymbolName: String,
        isWarning: Bool,
        errorText: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        tertiaryAction: String = "",
        tertiaryTitle: String = "",
        retryCommand: String,
        speedText: String = ""
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
            modeSymbolName: modeSymbolName,
            isWarning: isWarning,
            errorText: errorText,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            tertiaryAction: tertiaryAction,
            tertiaryTitle: tertiaryTitle,
            retryCommand: retryCommand,
            speedText: speedText.isEmpty ? speedLabel(speedMetersPerSecond: speedMetersPerSecond) : speedText
        )
    }

    private static func speedLabel(speedMetersPerSecond: Double) -> String {
        guard speedMetersPerSecond > 0 else { return "" }
        return RouteSpeedPreset.compactText(kilometersPerHour: speedMetersPerSecond * 3.6)
    }

    private static func speedCycleTitle(speedMetersPerSecond: Double) -> String {
        let next = RouteSpeedPreset.nextKilometersPerHour(after: speedMetersPerSecond * 3.6)
        return RouteSpeedPreset.compactText(kilometersPerHour: next)
    }
}

func sanitizedActions(
    primary: String,
    primaryTitle: String,
    secondary: String,
    secondaryTitle: String,
    tertiary: String = "",
    tertiaryTitle: String = "",
    allowed: Set<String>
) -> (primary: String, primaryTitle: String, secondary: String, secondaryTitle: String, tertiary: String, tertiaryTitle: String) {
    let items = [
        (primary, primaryTitle),
        (secondary, secondaryTitle),
        (tertiary, tertiaryTitle)
    ]
    .filter { isAllowedIslandAction($0.0, allowed: allowed) }
    var unique: [(String, String)] = []
    for item in items {
        if unique.contains(where: { $0.0 == item.0 || conflicts(unique.last?.0 ?? "", item.0) }) {
            continue
        }
        unique.append(item)
    }
    func at(_ index: Int) -> (String, String) {
        index < unique.count ? unique[index] : ("", "")
    }
    let first = at(0)
    let second = at(1)
    let third = at(2)
    return (first.0, first.1, second.0, second.1, third.0, third.1)
}

func isAllowedIslandAction(_ action: String, allowed: Set<String>) -> Bool {
    if action.isEmpty { return false }
    if allowed.contains(action) { return true }
    if allowed.contains("switchFavorite"), IslandFavoriteCommand.favoriteID(from: action) != nil {
        return true
    }
    return false
}

func conflicts(_ primary: String, _ secondary: String) -> Bool {
    guard !primary.isEmpty, !secondary.isEmpty else { return false }
    let pair = Set([primary, secondary])
    return pair == ["pause", "resume"]
        || pair == ["stopRoute", "stopSpoof"]
        || pair == ["switchHere", "pause"]
        || pair == ["switchHere", "resume"]
        || pair == ["stopSpoof", "pause"]
        || pair == ["stopSpoof", "resume"]
}
