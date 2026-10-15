import SwiftUI

/// 首页 sheet 需要的对象引用。外壳不观察这些 Store，避免地图刷新打断设置滚动。
@MainActor
final class MapHomeSheetBox: ObservableObject {
    var actions: LocationActionCoordinator?
    var favoriteImport: FavoriteImportCoordinator?
    var favorites: FavoriteLocationStore?
    var session: SpoofSession?
    var savedRoutes: SavedRouteStore?
    var recentRoutes: RecentRouteStore?
    var routeImport: RouteImportCoordinator?
    var testFavorite: FavoriteLocation?
    var physicalWalk: PhysicalWalkController?
    var mapState: MapLocationState?
    var routeClock: RoutePlaybackClock?
    weak var mapCoordinator: MapViewRepresentable.Coordinator?
    @Published var activeSheet: HomeSheet?
    var onSelectFavorite: (FavoriteLocation) -> Void = { _ in }
    var onRenameFavorite: (FavoriteLocation, String) -> Void = { _, _ in }
    var onSelectSavedRoute: (SavedRoute) -> Void = { _ in }

    func coverHome() {
        physicalWalk?.setPublishesUI(false)
        mapState?.setPublishesRealtime(false)
        routeClock?.setPublishesUI(false)
        guard let coordinator = mapCoordinator, let map = coordinator.map else { return }
        coordinator.setSuspended(true, on: map)
    }

    func uncoverHome() {
        physicalWalk?.setPublishesUI(true)
        mapState?.setPublishesRealtime(true)
        routeClock?.setPublishesUI(true)
        guard let coordinator = mapCoordinator, let map = coordinator.map else { return }
        coordinator.setSuspended(false, on: map)
    }

    func bindRuntime(
        actions: LocationActionCoordinator,
        favoriteImport: FavoriteImportCoordinator,
        favorites: FavoriteLocationStore,
        session: SpoofSession,
        savedRoutes: SavedRouteStore,
        recentRoutes: RecentRouteStore,
        routeImport: RouteImportCoordinator,
        testFavorite: FavoriteLocation
    ) {
        self.actions = actions
        self.favoriteImport = favoriteImport
        self.favorites = favorites
        self.session = session
        self.savedRoutes = savedRoutes
        self.recentRoutes = recentRoutes
        self.routeImport = routeImport
        self.testFavorite = testFavorite
    }
}

/// 设置等 sheet 挂在这里，不跟首页的高频 Store 一起失效。
/// 外壳因 sheet 失效时，用相等性跳过首页 body，避免点设置卡在整页重绘上。
struct MapHomeHost: View, Equatable {
    let setup: SetupCoordinator
    let sheetBox: MapHomeSheetBox

    static func == (lhs: MapHomeHost, rhs: MapHomeHost) -> Bool {
        lhs.setup === rhs.setup && lhs.sheetBox === rhs.sheetBox
    }

    var body: some View {
        MapHomeView(setup: setup, sheetBox: sheetBox)
    }
}

struct MapHomeContainer: View {
    @ObservedObject var setup: SetupCoordinator
    @StateObject private var sheetBox = MapHomeSheetBox()

    var body: some View {
        MapHomeHost(setup: setup, sheetBox: sheetBox)
            .equatable()
            .sheet(item: $sheetBox.activeSheet) { sheet in
                MapHomePresentedSheet(
                    sheet: sheet,
                    setup: setup,
                    box: sheetBox,
                    activeSheet: $sheetBox.activeSheet
                )
            }
            .onChange(of: sheetBox.activeSheet) { sheet in
                if sheet == nil {
                    sheetBox.uncoverHome()
                }
                if sheet != .settings {
                    sheetBox.favoriteImport?.leavePage()
                }
                if sheet != .savedRoutes {
                    sheetBox.routeImport?.leavePage()
                }
            }
    }
}

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
