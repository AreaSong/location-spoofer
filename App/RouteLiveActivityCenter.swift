import ActivityKit
import Foundation
import UIKit

@available(iOS 16.2, *)
@MainActor
final class RouteLiveActivityCenter {
    static let shared = RouteLiveActivityCenter()

    private var activity: Activity<RouteActivityAttributes>?
    private var last: RouteActivitySnapshot?
    private var generation = 0

    func sync(route: RoutePlaybackController) async {
        generation += 1
        let token = generation
        let next = RouteActivitySync.snapshot(
            phase: route.phase,
            statusMessage: route.statusMessage,
            routeName: route.editingSavedRoute?.name ?? "\(route.travelMode.displayName)路线",
            remainingMeters: route.remainingMeters,
            speedMetersPerSecond: route.speedMetersPerSecond,
            progress: route.progress,
            symbolName: route.travelMode == .bike ? "bicycle" : "figure.walk"
        )
        guard token == generation else { return }
        if let next {
            await present(next, token: token)
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

    private func present(_ next: RouteActivitySnapshot, token: Int) async {
        guard RouteActivitySync.shouldUpdate(last, to: next) else { return }
        let becomingFinished = next.phaseKey == .finished && last?.phaseKey != .finished
        let state = contentState(from: next)
        let content = ActivityContent(state: state, staleDate: nil)
        if activity == nil {
            activity = try? Activity.request(attributes: RouteActivityAttributes(routeName: next.routeName), content: content, pushType: nil)
        }
        guard let activity else { return }
        if becomingFinished {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await activity.update(content, alertConfiguration: AlertConfiguration(
                title: "路线走完",
                body: LocalizedStringResource(stringLiteral: next.statusText),
                sound: .default
            ))
            guard token == generation else { return }
            last = next
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30)))
            self.activity = nil
            return
        }
        await activity.update(content)
        guard token == generation else { return }
        last = next
    }

    private func endNow() async {
        last = nil
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }

    private func contentState(from snapshot: RouteActivitySnapshot) -> RouteActivityAttributes.ContentState {
        let trailing: String
        if snapshot.isWarning {
            trailing = "异常"
        } else if snapshot.phaseKey == .paused {
            trailing = "暂停"
        } else if snapshot.phaseKey == .finished {
            trailing = "完成"
        } else {
            trailing = "\(snapshot.remainingMinutes)分"
        }
        return RouteActivityAttributes.ContentState(
            phaseKey: snapshot.phaseKey.rawValue,
            statusText: snapshot.statusText,
            remainingText: snapshot.remainingText,
            routeName: snapshot.routeName,
            progress: snapshot.progress,
            symbolName: snapshot.symbolName,
            isWarning: snapshot.isWarning,
            canToggle: snapshot.canToggle,
            compactTrailing: trailing
        )
    }
}
