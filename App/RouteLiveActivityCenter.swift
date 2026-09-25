import ActivityKit
import Foundation
import UIKit

@available(iOS 16.2, *)
@MainActor
final class RouteLiveActivityCenter {
    static let shared = RouteLiveActivityCenter()

    private var activity: Activity<RouteActivityAttributes>?
    private var lastRoute: RouteActivitySnapshot?
    private var lastSpot: SpotActivitySnapshot?
    private var holdingFinished = false
    private var generation = 0
    private var closedRouteTerminal: RouteActivityPhaseKey?
    private var closedSpotStop = false

    func sync(route: RouteActivitySnapshot?, spot: SpotActivitySnapshot?, keepForRecovery: Bool = false) async {
        generation += 1
        let token = generation
        holdingFinished = false
        if let route {
            await presentRoute(route, token: token)
            return
        }
        if let spot {
            await presentSpot(spot, token: token)
        } else if keepForRecovery {
            return
        } else {
            await endNow()
        }
    }

    func reconcileOnLaunch(hasRecoverableSession: Bool) async {
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
        await endNow()
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
        guard let activity else { return }
        if becomingTerminal {
            holdingFinished = true
            if next.phaseKey == .finished {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            let dismissed = await publish(activity, content, alert: next.phaseKey == .finished)
            guard token == generation else {
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
            lastRoute = nil
            holdingFinished = false
            closedRouteTerminal = next.phaseKey
            return
        }
        guard await publish(activity, content, alert: false) else { return }
        guard token == generation else { return }
        lastRoute = next
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
        guard let activity else { return }
        if next.status == .stopped {
            guard await publish(activity, content, alert: false) else { return }
            guard token == generation else { return }
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3)))
            self.activity = nil
            lastSpot = nil
            closedSpotStop = true
            return
        }
        guard await publish(activity, content, alert: false) else { return }
        guard token == generation else { return }
        lastSpot = next
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

    private func endNow() async {
        lastRoute = nil
        lastSpot = nil
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
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
