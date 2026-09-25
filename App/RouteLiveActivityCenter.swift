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

    func sync(route: RouteActivitySnapshot?, spot: SpotActivitySnapshot?) async {
        generation += 1
        let token = generation
        if let route {
            await presentRoute(route, token: token)
            return
        }
        guard !holdingFinished else { return }
        if let spot {
            await presentSpot(spot, token: token)
        } else {
            await endNow()
        }
    }

    func endStaleActivities() async {
        guard activity == nil else { return }
        for existing in Activity<RouteActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func presentRoute(_ next: RouteActivitySnapshot, token: Int) async {
        guard RouteActivitySync.shouldUpdate(lastRoute, to: next) || lastSpot != nil else { return }
        let becomingFinished = next.phaseKey == .finished && lastRoute?.phaseKey != .finished
        lastSpot = nil
        let state = routeState(next)
        let content = ActivityContent(state: state, staleDate: nil)
        await ensureActivity(name: next.routeName, content: content)
        guard let activity else { return }
        if becomingFinished {
            holdingFinished = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await activity.update(content, alertConfiguration: AlertConfiguration(
                title: "路线走完",
                body: "完成",
                sound: .default
            ))
            guard token == generation else { return }
            lastRoute = next
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
            self.activity = nil
            lastRoute = nil
            holdingFinished = false
            return
        }
        await activity.update(content)
        guard token == generation else { return }
        lastRoute = next
    }

    private func presentSpot(_ next: SpotActivitySnapshot, token: Int) async {
        guard SpotActivitySync.shouldUpdate(lastSpot, to: next) || lastRoute != nil else { return }
        lastRoute = nil
        let state = spotState(next)
        let content = ActivityContent(state: state, staleDate: nil)
        await ensureActivity(name: next.placeName, content: content)
        guard let activity else { return }
        await activity.update(content)
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
                details: ["name": name]
            )
            activity = Activity<RouteActivityAttributes>.activities.first
        }
    }

    private func endNow() async {
        lastRoute = nil
        lastSpot = nil
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    private func routeState(_ snapshot: RouteActivitySnapshot) -> RouteActivityAttributes.ContentState {
        RouteActivityAttributes.ContentState(
            kind: "route",
            title: snapshot.routeName,
            statusText: snapshot.statusText,
            detailText: snapshot.detailText,
            progress: snapshot.progress,
            showsProgress: snapshot.statusText.hasSuffix("分") || snapshot.statusText == "暂停" || snapshot.statusText == "异常" || snapshot.statusText == "完成",
            symbolName: snapshot.symbolName,
            isWarning: snapshot.isWarning,
            showsRoute: true,
            action: snapshot.action,
            actionTitle: snapshot.actionTitle
        )
    }

    private func spotState(_ snapshot: SpotActivitySnapshot) -> RouteActivityAttributes.ContentState {
        RouteActivityAttributes.ContentState(
            kind: "spot",
            title: snapshot.placeName,
            statusText: snapshot.statusText,
            detailText: snapshot.caption,
            progress: 0,
            showsProgress: false,
            symbolName: snapshot.symbolName,
            isWarning: snapshot.isWarning,
            showsRoute: false,
            action: snapshot.action,
            actionTitle: snapshot.actionTitle
        )
    }
}
