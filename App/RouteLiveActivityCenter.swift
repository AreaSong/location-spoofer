import ActivityKit
import Foundation
import UIKit

@available(iOS 16.2, *)
@MainActor
final class RouteLiveActivityCenter {
    static let shared = RouteLiveActivityCenter()

    private struct SyncRequest {
        var route: RouteActivitySnapshot?
        var spot: SpotActivitySnapshot?
        var keepForRecovery: Bool
        var token: Int
    }

    private var activity: Activity<RouteActivityAttributes>?
    private var lastRoute: RouteActivitySnapshot?
    private var lastSpot: SpotActivitySnapshot?
    private var holdingFinished = false
    private var generation = 0
    private var queued: SyncRequest?
    private var draining = false
    private var closedRouteTerminal: RouteActivityPhaseKey?
    private var closedSpotStop = false
    private var creationFailures = 0
    private var failedCreationKey: String?
    private var creationRetryTask: Task<Void, Never>?
    private var pendingCreation: SyncRequest?
    private var allowDeferredCreationAttempt = false

    func sync(route: RouteActivitySnapshot?, spot: SpotActivitySnapshot?, keepForRecovery: Bool = false) async {
        enqueue(route: route, spot: spot, keepForRecovery: keepForRecovery)
        await drain()
    }

    func reconcileOnLaunch(hasRecoverableSession: Bool) async {
        generation += 1
        holdingFinished = false
        switch ActivityRunPolicy.launchDecision(hasRecoverableSession: hasRecoverableSession) {
        case .endStale:
            await endStaleActivities(hasRecoverableSession: hasRecoverableSession)
        }
    }

    func endNowIfIdle() async {
        enqueue(route: nil, spot: nil, keepForRecovery: false)
        await drain()
    }

    private func enqueue(route: RouteActivitySnapshot?, spot: SpotActivitySnapshot?, keepForRecovery: Bool) {
        generation += 1
        holdingFinished = false
        queued = SyncRequest(route: route, spot: spot, keepForRecovery: keepForRecovery, token: generation)
    }

    /// 同一时间只应用最新一次同步。旧任务在发布或结束前退出，避免把新状态盖掉或收起。
    private func drain() async {
        if draining { return }
        draining = true
        defer { draining = false }
        while let request = queued {
            queued = nil
            await apply(request)
        }
    }

    private func apply(_ request: SyncRequest) async {
        guard !superseded(request.token) else { return }
        pendingCreation = request
        prepareCreationBudget(for: request)
        if let route = request.route {
            await presentRoute(route, token: request.token)
            return
        }
        if let spot = request.spot {
            await presentSpot(spot, token: request.token)
            return
        }
        if ActivityRunPolicy.shouldDismissWithoutSnapshot(keepForRecovery: request.keepForRecovery) {
            await endNow(token: request.token)
        }
    }

    private func superseded(_ token: Int) -> Bool {
        queued != nil || token != generation
    }

    private func presentRoute(_ next: RouteActivitySnapshot, token: Int) async {
        if ActivityRunPolicy.blocksNewWork(holdingFinished: holdingFinished) { return }
        holdingFinished = false
        let contentChanged = RouteActivitySync.shouldUpdate(lastRoute, to: next) || lastSpot != nil
        guard needsPublish(contentChanged: contentChanged) else { return }
        let next = RouteActivitySync.normalized(next)
        if next.phaseKey == .finished || next.phaseKey == .stopped {
            if activity == nil, closedRouteTerminal == next.phaseKey {
                return
            }
        } else {
            closedRouteTerminal = nil
        }
        closedSpotStop = false
        let ending = next.phaseKey == .finished || next.phaseKey == .stopped
        let becomingTerminal = ending && lastRoute?.phaseKey != next.phaseKey
        lastSpot = nil
        let state = routeState(next)
        let content = ActivityContent(state: state, staleDate: RouteActivitySync.staleDate(for: next))
        await ensureActivity(name: next.routeName, content: content, token: token)
        guard !superseded(token), let activity else { return }
        if becomingTerminal {
            await finishRoute(next, activity: activity, content: content, token: token)
            return
        }
        guard !superseded(token) else { return }
        guard await publish(activity, content, alert: false) else {
            if !superseded(token) { lastRoute = nil }
            return
        }
        guard !superseded(token) else { return }
        lastRoute = next
    }

    private func finishRoute(
        _ next: RouteActivitySnapshot,
        activity: Activity<RouteActivityAttributes>,
        content: ActivityContent<RouteActivityAttributes.ContentState>,
        token: Int
    ) async {
        guard !superseded(token) else { return }
        // 完成态标记只活在这次结束里。离开函数就必须放开，避免挡住下一次定位。
        holdingFinished = true
        defer { holdingFinished = false }
        if next.phaseKey == .finished {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let dismissed = await publish(activity, content, alert: next.phaseKey == .finished)
        guard !superseded(token) else { return }
        guard dismissed else { return }
        let seconds: TimeInterval = next.phaseKey == .finished ? 30 : RouteActivitySync.stoppedConfirmInterval
        let endedID = activity.id
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(seconds)))
        if self.activity?.id == endedID {
            self.activity = nil
        }
        guard !superseded(token) else { return }
        await endActivities(except: endedID)
        guard !superseded(token) else { return }
        lastRoute = nil
        closedRouteTerminal = next.phaseKey
    }

    private func presentSpot(_ next: SpotActivitySnapshot, token: Int) async {
        if ActivityRunPolicy.blocksNewWork(holdingFinished: holdingFinished) { return }
        holdingFinished = false
        let next = SpotActivitySync.normalized(next)
        if next.status == .stopped {
            if activity == nil, closedSpotStop {
                return
            }
        } else {
            closedSpotStop = false
        }
        let contentChanged = SpotActivitySync.shouldUpdate(lastSpot, to: next) || lastRoute != nil
        guard needsPublish(contentChanged: contentChanged) else { return }
        if next.status == .actionFailed || next.status == .notApplied, lastSpot?.status != next.status {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        lastRoute = nil
        closedRouteTerminal = nil
        let state = spotState(next)
        let content = ActivityContent(state: state, staleDate: SpotActivitySync.staleDate(for: next))
        await ensureActivity(name: next.placeName, content: content, token: token)
        guard !superseded(token), let activity else { return }
        if next.status == .stopped {
            await finishSpot(activity, content: content, token: token)
            return
        }
        guard !superseded(token) else { return }
        guard await publish(activity, content, alert: false) else {
            if !superseded(token) { lastSpot = nil }
            return
        }
        guard !superseded(token) else { return }
        lastSpot = next
    }

    private func finishSpot(
        _ activity: Activity<RouteActivityAttributes>,
        content: ActivityContent<RouteActivityAttributes.ContentState>,
        token: Int
    ) async {
        guard !superseded(token) else { return }
        guard await publish(activity, content, alert: false) else { return }
        guard !superseded(token) else { return }
        let endedID = activity.id
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3)))
        if self.activity?.id == endedID {
            self.activity = nil
        }
        guard !superseded(token) else { return }
        await endActivities(except: endedID)
        guard !superseded(token) else { return }
        lastSpot = nil
        closedSpotStop = true
    }

    private func ensureActivity(
        name: String,
        content: ActivityContent<RouteActivityAttributes.ContentState>,
        token: Int
    ) async {
        if let activity {
            if ActivityRunPolicy.shouldReplace(runtimeState(of: activity)) {
                await activity.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            } else {
                await endActivities(except: activity.id)
                noteCreationSucceeded()
                return
            }
        }
        await requestActivity(name: name, content: content, token: token)
    }

    /// 创建失败先立刻再试一次，仍失败就延后重放当前快照。次数用完后停止，避免空转。
    private func requestActivity(
        name: String,
        content: ActivityContent<RouteActivityAttributes.ContentState>,
        token: Int
    ) async {
        while !superseded(token) {
            if !allowDeferredCreationAttempt, creationFailures > 0 {
                switch ActivityRunPolicy.creationPlan(failureCount: creationFailures) {
                case .retryImmediately:
                    break
                case .retryLater:
                    scheduleCreationRetry()
                    return
                case .stop:
                    return
                }
            }
            allowDeferredCreationAttempt = false
            do {
                let created = try Activity.request(
                    attributes: RouteActivityAttributes(name: name),
                    content: content,
                    pushType: nil
                )
                guard !superseded(token) else {
                    await created.end(nil, dismissalPolicy: .immediate)
                    return
                }
                activity = created
                noteCreationSucceeded()
                await endActivities(except: created.id)
                return
            } catch {
                RuntimeLogger.error(
                    "RouteLiveActivity",
                    "activity",
                    "创建灵动岛失败",
                    error: error,
                    details: ["phase": content.state.phase]
                )
                guard !superseded(token) else { return }
                activity = await adoptedActivity()
                if activity != nil {
                    noteCreationSucceeded()
                    return
                }
                creationFailures += 1
                RuntimeLogger.error(
                    "RouteLiveActivity",
                    "activity",
                    "创建灵动岛失败，且没有可接管的活动",
                    details: ["phase": content.state.phase, "failures": String(creationFailures)]
                )
                switch ActivityRunPolicy.creationPlan(failureCount: creationFailures) {
                case .retryImmediately:
                    continue
                case .retryLater:
                    scheduleCreationRetry()
                    return
                case .stop:
                    return
                }
            }
        }
    }

    private func noteCreationSucceeded() {
        creationFailures = 0
        failedCreationKey = nil
        creationRetryTask?.cancel()
        creationRetryTask = nil
    }

    /// 进度刷新会反复同步同一条快照。已安排的延后重试不重置，避免每次都重新创建。
    private func prepareCreationBudget(for request: SyncRequest) {
        let key = creationKey(for: request)
        guard ActivityRunPolicy.shouldResetCreationFailures(previousKey: failedCreationKey, key: key) else { return }
        failedCreationKey = key
        creationFailures = 0
        creationRetryTask?.cancel()
        creationRetryTask = nil
    }

    private func creationKey(for request: SyncRequest) -> String {
        if let route = request.route {
            return "route:\(route.phaseKey.rawValue):\(route.statusText):\(route.primaryAction)"
        }
        if let spot = request.spot {
            return "spot:\(spot.status.rawValue):\(spot.statusText):\(spot.primaryAction)"
        }
        return "idle"
    }

    private func scheduleCreationRetry() {
        guard creationRetryTask == nil else { return }
        creationRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self.creationRetryTask = nil
            guard self.activity == nil, var request = self.pendingCreation else { return }
            guard ActivityRunPolicy.creationPlan(failureCount: self.creationFailures) == .retryLater else { return }
            guard self.queued == nil, !self.draining else {
                self.scheduleCreationRetry()
                return
            }
            request.token = self.generation
            self.allowDeferredCreationAttempt = true
            await self.apply(request)
        }
    }

    /// 新建失败时接上系统里已有的那一条，随后由调用方写成当前阶段。
    private func adoptedActivity() async -> Activity<RouteActivityAttributes>? {
        let existing = Activity<RouteActivityAttributes>.activities
        guard let first = existing.first else { return nil }
        for extra in existing.dropFirst() {
            await extra.end(nil, dismissalPolicy: .immediate)
        }
        return first
    }

    private func publish(
        _ activity: Activity<RouteActivityAttributes>,
        _ content: ActivityContent<RouteActivityAttributes.ContentState>,
        alert: Bool
    ) async -> Bool {
        guard acceptUpdate(of: activity, phase: content.state.phase, moment: "更新前") else { return false }
        if alert {
            await activity.update(content, alertConfiguration: AlertConfiguration(
                title: "路线走完",
                body: "完成",
                sound: .default
            ))
        } else {
            await activity.update(content)
        }
        return acceptUpdate(of: activity, phase: content.state.phase, moment: "更新后")
    }

    private func acceptUpdate(
        of activity: Activity<RouteActivityAttributes>,
        phase: String,
        moment: String
    ) -> Bool {
        let state = runtimeState(of: activity)
        guard ActivityRunPolicy.updateAccepted(state) else {
            RuntimeLogger.error(
                "RouteLiveActivity",
                "activity",
                "更新灵动岛失败",
                details: ["phase": phase, "moment": moment, "state": String(describing: state)]
            )
            if self.activity?.id == activity.id {
                self.activity = nil
            }
            return false
        }
        return true
    }

    private func needsPublish(contentChanged: Bool) -> Bool {
        let runtime = activity.flatMap { runtimeState(of: $0) }
        return ActivityRunPolicy.shouldPublish(
            contentChanged: contentChanged,
            runtime: runtime,
            activityMissing: activity == nil && creationFailures > 0
        )
    }

    private func runtimeState(of activity: Activity<RouteActivityAttributes>) -> ActivityRuntimeState? {
        guard Activity<RouteActivityAttributes>.activities.contains(where: { $0.id == activity.id }) else {
            return nil
        }
        switch activity.activityState {
        case .active:
            return .active
        case .ended:
            return .ended
        case .dismissed:
            return .dismissed
        case .stale:
            return .stale
        default:
            return .pending
        }
    }

    private func endActivities(except keptID: String?) async {
        let ids = Activity<RouteActivityAttributes>.activities.map(\.id)
        let ending = Set(ActivityRunPolicy.idsToEnd(existing: ids, keeping: keptID))
        for activity in Activity<RouteActivityAttributes>.activities where ending.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func endStaleActivities(hasRecoverableSession: Bool) async {
        let existing = Activity<RouteActivityAttributes>.activities
        if !existing.isEmpty {
            RuntimeLogger.info(
                "RouteLiveActivity",
                "lifecycle",
                "结束重启后的陈旧灵动岛",
                details: [
                    "recoverable": String(hasRecoverableSession),
                    "count": String(existing.count)
                ]
            )
        }
        for activity in existing {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        lastRoute = nil
        lastSpot = nil
        closedRouteTerminal = nil
        closedSpotStop = false
    }

    private func endNow(token: Int) async {
        guard !superseded(token) else { return }
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
        }
        guard !superseded(token) else { return }
        await endActivities(except: nil)
        guard !superseded(token) else { return }
        lastRoute = nil
        lastSpot = nil
        closedRouteTerminal = nil
        closedSpotStop = false
    }

    private func routeDetail(_ snapshot: RouteActivitySnapshot) -> String {
        RouteActivitySync.detailText(for: snapshot)
    }

    private func showsRouteProgress(_ phase: RouteActivityPhaseKey) -> Bool {
        switch phase {
        case .playing, .userPaused, .systemFault, .retrying, .finished, .actionFailed:
            return true
        case .stopped, .planning:
            return false
        }
    }

    private func routeState(_ snapshot: RouteActivitySnapshot) -> RouteActivityAttributes.ContentState {
        RouteActivityAttributes.ContentState(
            kind: "route",
            title: snapshot.routeName,
            statusText: snapshot.statusText,
            detailText: routeDetail(snapshot),
            distanceText: snapshot.distanceText,
            timeText: snapshot.timeText,
            progress: min(max(snapshot.progress, 0), 1),
            showsProgress: showsRouteProgress(snapshot.phaseKey),
            symbolName: snapshot.symbolName,
            modeSymbolName: snapshot.modeSymbolName,
            isWarning: snapshot.isWarning,
            primaryAction: snapshot.primaryAction,
            primaryTitle: snapshot.primaryTitle,
            secondaryAction: snapshot.secondaryAction,
            secondaryTitle: snapshot.secondaryTitle,
            phase: snapshot.phaseKey.rawValue,
            errorText: snapshot.errorText,
            retryCommand: snapshot.retryCommand
        )
    }

    private func spotState(_ snapshot: SpotActivitySnapshot) -> RouteActivityAttributes.ContentState {
        RouteActivityAttributes.ContentState(
            kind: "spot",
            title: snapshot.placeName,
            statusText: snapshot.statusText,
            detailText: snapshot.caption,
            distanceText: "",
            timeText: "",
            progress: 0,
            showsProgress: false,
            symbolName: snapshot.symbolName,
            isWarning: snapshot.isWarning,
            primaryAction: snapshot.primaryAction,
            primaryTitle: snapshot.primaryTitle,
            secondaryAction: snapshot.secondaryAction,
            secondaryTitle: snapshot.secondaryTitle,
            phase: snapshot.status.rawValue,
            errorText: snapshot.errorText,
            retryCommand: snapshot.retryCommand
        )
    }
}
