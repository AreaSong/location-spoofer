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

    func sync(route: RouteActivitySnapshot?, spot: SpotActivitySnapshot?, keepForRecovery: Bool = false) async {
        enqueue(route: route, spot: spot, keepForRecovery: keepForRecovery)
        await drain()
    }

    func reconcileOnLaunch(hasRecoverableSession: Bool) async {
        generation += 1
        holdingFinished = false
        let existing = Activity<RouteActivityAttributes>.activities
        if hasRecoverableSession, let first = existing.first {
            activity = first
            for extra in existing.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        for activity in existing {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
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
        if let route = request.route {
            await presentRoute(route, token: request.token)
            return
        }
        if let spot = request.spot {
            await presentSpot(spot, token: request.token)
            return
        }
        if request.keepForRecovery { return }
        await endNow(token: request.token)
    }

    private func superseded(_ token: Int) -> Bool {
        queued != nil || token != generation
    }

    private func presentRoute(_ next: RouteActivitySnapshot, token: Int) async {
        guard RouteActivitySync.shouldUpdate(lastRoute, to: next) || lastSpot != nil else { return }
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
        await ensureActivity(name: next.routeName, content: content)
        guard !superseded(token), let activity else { return }
        if becomingTerminal {
            await finishRoute(next, activity: activity, content: content, token: token)
            return
        }
        guard !superseded(token) else { return }
        guard await publish(activity, content, alert: false) else { return }
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
        holdingFinished = true
        if next.phaseKey == .finished {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let dismissed = await publish(activity, content, alert: next.phaseKey == .finished)
        guard !superseded(token) else {
            holdingFinished = false
            return
        }
        guard dismissed else {
            holdingFinished = false
            return
        }
        let seconds: TimeInterval = next.phaseKey == .finished ? 30 : 3
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(seconds)))
        self.activity = nil
        guard !superseded(token) else {
            holdingFinished = false
            return
        }
        lastRoute = nil
        holdingFinished = false
        closedRouteTerminal = next.phaseKey
    }

    private func presentSpot(_ next: SpotActivitySnapshot, token: Int) async {
        let next = SpotActivitySync.normalized(next)
        if next.status == .stopped {
            if activity == nil, closedSpotStop {
                return
            }
        } else {
            closedSpotStop = false
        }
        guard SpotActivitySync.shouldUpdate(lastSpot, to: next) || lastRoute != nil else { return }
        lastRoute = nil
        closedRouteTerminal = nil
        let state = spotState(next)
        let content = ActivityContent(state: state, staleDate: SpotActivitySync.staleDate(for: next))
        await ensureActivity(name: next.placeName, content: content)
        guard !superseded(token), let activity else { return }
        if next.status == .stopped {
            await finishSpot(activity, content: content, token: token)
            return
        }
        guard !superseded(token) else { return }
        guard await publish(activity, content, alert: false) else { return }
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
        await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3)))
        self.activity = nil
        guard !superseded(token) else { return }
        lastSpot = nil
        closedSpotStop = true
    }

    private func ensureActivity(name: String, content: ActivityContent<RouteActivityAttributes.ContentState>) async {
        guard activity == nil else { return }
        do {
            activity = try Activity.request(
                attributes: RouteActivityAttributes(name: name),
                content: content,
                pushType: nil
            )
        } catch {
            RuntimeLogger.error(
                "RouteLiveActivity",
                "activity",
                "创建灵动岛失败",
                error: error,
                details: ["phase": content.state.phase]
            )
            activity = nil
        }
    }

    private func publish(
        _ activity: Activity<RouteActivityAttributes>,
        _ content: ActivityContent<RouteActivityAttributes.ContentState>,
        alert: Bool
    ) async -> Bool {
        if alert {
            await activity.update(content, alertConfiguration: AlertConfiguration(
                title: "路线走完",
                body: "完成",
                sound: .default
            ))
        } else {
            await activity.update(content)
        }
        return true
    }

    private func endNow(token: Int) async {
        guard !superseded(token), let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
        guard !superseded(token) else { return }
        lastRoute = nil
        lastSpot = nil
    }

    private func routeDetail(_ snapshot: RouteActivitySnapshot) -> String {
        if !snapshot.distanceText.isEmpty, !snapshot.timeText.isEmpty {
            return "还剩 \(snapshot.distanceText) · \(snapshot.timeText)"
        }
        if !snapshot.distanceText.isEmpty {
            return "还剩 \(snapshot.distanceText)"
        }
        return snapshot.timeText
    }

    private func showsRouteProgress(_ phase: RouteActivityPhaseKey) -> Bool {
        switch phase {
        case .playing, .userPaused, .systemFault, .retrying, .finished:
            return true
        case .stopped, .actionFailed:
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
