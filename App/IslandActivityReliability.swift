import Foundation

enum IslandCommandDecision: Equatable {
    case run
    case alreadySatisfied
    case leaveCurrent
    case unavailable(String)
}

struct IslandCommandContext: Equatable {
    var routePhase: RoutePhase
    var interruption: RouteInterruption
    var statusMessage: String
    var waitingForActivation: Bool
    var spoofState: SpoofState
    var needsSwitch: Bool
    var spotStopPending: Bool
    var spotSwitchPending: Bool
    var retryCommand: String
}

enum IslandCommandRouter {
    static func resolve(_ action: String, context: IslandCommandContext) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "retry" else { return trimmed }
        if !context.retryCommand.isEmpty { return context.retryCommand }
        if context.interruption == .activationFailed { return "play" }
        switch context.routePhase {
        case .playing:
            return "play"
        case .paused:
            return "resume"
        case .inactive, .preparing, .finished:
            break
        }
        if context.spoofState == .active, context.needsSwitch { return "switchHere" }
        if context.spoofState != .idle { return "begin" }
        return trimmed
    }

    static func decide(_ action: String, context: IslandCommandContext) -> IslandCommandDecision {
        switch action {
        case "pause":
            return pauseDecision(context)
        case "resume", "play":
            return resumeDecision(context)
        case "stopRoute":
            return stopRouteDecision(context)
        case "stopSpoof":
            return stopSpoofDecision(context)
        case "switchHere":
            return switchDecision(context)
        case "begin":
            return beginDecision(context)
        case "openApp":
            return .alreadySatisfied
        case "retry":
            return .unavailable("没有可重试的操作。")
        default:
            return .unavailable("不支持这个操作。")
        }
    }

    private static func pauseDecision(_ context: IslandCommandContext) -> IslandCommandDecision {
        if context.routePhase == .playing { return .run }
        if context.routePhase == .paused, context.interruption == .userPaused {
            return .alreadySatisfied
        }
        if context.routePhase == .paused { return .leaveCurrent }
        return .unavailable("现在不能暂停路线。")
    }

    private static func resumeDecision(_ context: IslandCommandContext) -> IslandCommandDecision {
        if context.waitingForActivation || context.routePhase == .playing {
            return .alreadySatisfied
        }
        if context.routePhase == .paused || context.interruption == .activationFailed {
            return .run
        }
        return .unavailable("现在不能继续路线。")
    }

    private static func stopRouteDecision(_ context: IslandCommandContext) -> IslandCommandDecision {
        if context.routePhase == .playing || context.routePhase == .paused { return .run }
        if context.routePhase == .preparing, context.statusMessage == RouteActivitySync.stoppedMessage {
            return .alreadySatisfied
        }
        return .unavailable("现在没有可停止的路线。")
    }

    private static func stopSpoofDecision(_ context: IslandCommandContext) -> IslandCommandDecision {
        if routeBlocksSpot(context) {
            return .unavailable("路线仍在使用定位。停止路线不会关闭定位。")
        }
        if context.spotStopPending || context.spoofState == .idle {
            return .alreadySatisfied
        }
        if context.spoofState == .active || context.spoofState == .verifying {
            return .run
        }
        return .unavailable("现在不能停止虚拟定位。")
    }

    private static func switchDecision(_ context: IslandCommandContext) -> IslandCommandDecision {
        if let blocked = blockedSpotStart(context) { return blocked }
        if context.spoofState == .active, context.needsSwitch { return .run }
        if context.spoofState == .active { return .alreadySatisfied }
        return .unavailable("现在不能切换定位。")
    }

    private static func beginDecision(_ context: IslandCommandContext) -> IslandCommandDecision {
        if let blocked = blockedSpotStart(context) { return blocked }
        if context.spoofState == .active, context.needsSwitch { return .run }
        if context.spoofState == .active { return .alreadySatisfied }
        return .run
    }

    private static func blockedSpotStart(_ context: IslandCommandContext) -> IslandCommandDecision? {
        if routeBlocksSpot(context) {
            return .unavailable("路线还在使用定位，不能另开定点。")
        }
        if context.spotStopPending || context.spotSwitchPending || context.spoofState == .verifying {
            return .alreadySatisfied
        }
        return nil
    }

    private static func routeBlocksSpot(_ context: IslandCommandContext) -> Bool {
        context.waitingForActivation
            || context.routePhase == .playing
            || context.routePhase == .paused
    }
}

enum ActivityRuntimeState: Equatable {
    case active
    case ended
    case dismissed
    case stale
    case pending
}

enum ActivityLaunchDecision: Equatable {
    case endStale
}

enum ActivityRunPolicy {
    static func shouldReplace(_ state: ActivityRuntimeState?) -> Bool {
        switch state {
        case nil, .ended, .dismissed:
            return true
        case .active, .stale, .pending:
            return false
        }
    }

    static func updateAccepted(_ state: ActivityRuntimeState?) -> Bool {
        switch state {
        case .active, .stale, .pending:
            return true
        case nil, .ended, .dismissed:
            return false
        }
    }

    /// 完成态标记不能挡住下一次定点或路线。
    static func blocksNewWork(holdingFinished _: Bool) -> Bool {
        false
    }

    /// 没有可展示的快照时，可恢复会话只留在 App 内确认，不能把重启前的岛留着。
    static func shouldDismissWithoutSnapshot(keepForRecovery _: Bool) -> Bool {
        true
    }

    static func launchDecision(hasRecoverableSession _: Bool) -> ActivityLaunchDecision {
        .endStale
    }

    static func idsToEnd(existing: [String], keeping kept: String?) -> [String] {
        existing.filter { $0 != kept }
    }
}
