import SwiftUI

/// 只决定首页按钮的呈现与派发目标，定位、路线停止与确认仍由原控制器执行。
enum HomeSecondaryAction: Equatable {
    case exitRoute, stopLocation

    var title: String {
        switch self {
        case .exitRoute: return "停止"
        case .stopLocation: return "停止定位"
        }
    }

    static func resolve(routePhase: RoutePhase, waiting: Bool, showsRoute: Bool,
                        spoofState: SpoofState, needsSwitch: Bool) -> Self? {
        if routePhase == .playing || routePhase == .paused || waiting { return .exitRoute }
        if showsRoute { return nil }
        if spoofState == .active && needsSwitch { return .stopLocation }
        return nil
    }
}

extension MapHomeView {
    var homeSecondaryAction: HomeSecondaryAction? {
        HomeSecondaryAction.resolve(
            routePhase: route.phase, waiting: route.waitingForActivation,
            showsRoute: showsRoutePanelActive, spoofState: spoofState, needsSwitch: needsSwitchButton
        )
    }

    func handleHomeSecondaryTap() {
        switch homeSecondaryAction {
        case .exitRoute: requestExitRoute()
        case .stopLocation:
            if UIPreview.isEnabled() {
                session.setPreviewActive(false, latitude: nil, longitude: nil)
            } else {
                stopSpoofing()
            }
        case nil: break
        }
    }

    var homeViaActionTitle: String? {
        guard showsRoutePanelActive, route.start != nil else { return nil }
        switch route.phase {
        case .preparing, .playing, .paused: return "途经点"
        default: return nil
        }
    }

    var homeViaActionDisabled: Bool {
        route.isRouting || route.waitingForActivation || route.vias.count >= RoutePlaybackController.maxViaCount
    }

    func handleHomeViaTap() {
        route.addVia(currentSelectionPair)
    }

    var homeDisplayName: String {
        if showsRoutePanelActive {
            return route.editingSavedRoute?.name ?? "当前路线"
        }
        return mapState.displayName ?? "当前选点"
    }

    var homeSelectionStatus: String {
        if showsRoutePanelActive {
            if route.waitingForActivation { return "正在开启路线…" }
            if route.interruption == .pushFailed || route.interruption == .activationFailed {
                return route.statusMessage
            }
            switch route.phase {
            case .playing: return "正在沿路线移动"
            case .paused: return "路线已暂停"
            case .finished: return "路线已结束"
            case .preparing, .inactive:
                return route.start == nil || route.end == nil ? "先设起点，再设途经和终点" : "起终点已设 · 途经 \(route.vias.count) 处"
            }
        }
        if routeKeepsRunningWhileSpotShown { return "当前选点 · 路线仍占用定位" }
        if spotStopPending { return "正在停止定位…" }
        if spotSwitchPending { return "正在切换位置…" }
        if spotActionFailed || spotIslandFailed {
            return spotFailureMessage.isEmpty ? "操作失败，请重试" : spotFailureMessage
        }
        if needsSwitchButton { return "新选位置 · 尚未切换" }
        switch spoofState {
        case .idle: return "已选位置 · 尚未开始"
        case .verifying: return "正在验证并应用位置…"
        case .active: return "正在使用此位置"
        }
    }
}
