import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    /// 开发者隧道模式把路线直接推进系统定位；其余模式和定点一样，经本机代理或第三方客户端写入。
    var routeUsesDeveloperTunnel: Bool {
        runtimeMode.mode == .developerTunnel
    }

    @MainActor
    func registerRouteActivityToggle() {
        RouteActivityBridge.toggle = { [weak route] in
            guard let route else { return }
            if route.phase == .playing {
                route.pause()
                return
            }
            guard route.phase == .paused, route.statusMessage == RouteActivitySync.userPauseMessage else { return }
            playRoute()
        }
    }

    func syncRouteActivity(clearStale: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        let playback = route
        Task {
            if clearStale {
                await RouteLiveActivityCenter.shared.endStaleActivities()
            }
            await RouteLiveActivityCenter.shared.sync(route: playback)
        }
    }

    func bindRoutePlayback() {
        route.applyCoordinate = { pair in
            await applyRouteCoordinate(pair)
        }
    }

    func enterRoute() {
        if route.phase == .inactive {
            route.enter()
        }
    }

    func openSavedRoutes() {
        activeSheet = .savedRoutes
    }

    func promptSaveRoute() {
        guard route.canPlay, !route.isRouting else { return }
        saveRouteName = route.editingSavedRoute?.name
            ?? RoutePlayback.formattedDistance(route.distanceMeters)
        showSaveRouteAlert = true
    }

    func commitSaveRoute(overwrite: Bool) {
        let trimmed = saveRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = route.makeSavedRoute(name: trimmed, overwrite: overwrite) else { return }
        savedRoutes.save(snapshot)
        route.noteSaved(snapshot)
        route.statusMessage = overwrite
            ? "已覆盖「\(snapshot.name)」。"
            : "已保存「\(snapshot.name)」。"
    }

    func handleRoutePinTap(_ pin: RouteMapPin) {
        guard route.phase == .preparing else { return }
        if case let .via(number) = pin.role {
            route.removeVia(at: number - 1)
        }
    }

    func exitRoute() {
        let previous = route.phase
        route.exit()
        clearRouteLocationIfNeeded(from: previous, to: route.phase)
        showsRoutePanel = false
    }

    /// 播放中或暂停时退出要先确认；只是摆了图钉的话直接退。
    func requestExitRoute() {
        switch route.phase {
        case .playing, .paused:
            showExitRouteConfirm = true
        case .inactive, .preparing, .finished:
            exitRoute()
        }
    }

    var showsRoutePanelActive: Bool {
        route.phase != .inactive && showsRoutePanel
    }

    var showsRouteProgress: Bool {
        switch route.phase {
        case .playing, .paused, .finished: return true
        case .inactive, .preparing: return false
        }
    }

    var homePeekTitle: String {
        showsRoutePanelActive ? routePeekTitle : spotPeekTitle
    }

    var homePeekAccessibilityLabel: String {
        showsRoutePanelActive ? routePeekTitle : spotPeekAccessibilityLabel
    }

    var homePeekColor: Color {
        if showsRoutePanelActive { return .accentColor }
        if needsSwitchButton { return .blue }
        return buttonColor
    }

    var homePeekDisabled: Bool {
        showsRoutePanelActive ? routePeekDisabled : spoofState == .verifying
    }

    var homePeekOpensDetail: Bool {
        showsRoutePanelActive && routePeekOpensDetail
    }

    var routePeekTitle: String {
        switch route.phase {
        case .playing: return "暂停"
        case .paused: return "继续"
        case .preparing where route.start == nil: return "设为起点"
        case .preparing: return "设为终点"
        default: return "开始走"
        }
    }

    var routePeekOpensDetail: Bool { false }

    var routePeekDisabled: Bool {
        if route.phase == .playing { return false }
        if route.phase == .preparing, route.start == nil || route.end == nil || !route.canPlay {
            return route.isRouting
        }
        return !route.canPlay || route.waitingForActivation || route.isRouting
    }

    func handlePeekTap() {
        guard showsRoutePanelActive else {
            if needsSwitchButton {
                beginLocationOperation()
            } else {
                handleMainButtonTap()
            }
            return
        }
        switch route.phase {
        case .playing:
            route.pause()
        case .preparing where route.start == nil:
            route.setStart(currentSelectionPair)
        case .preparing where route.end == nil || !route.canPlay:
            route.setEnd(currentSelectionPair)
        default:
            playRoute()
        }
    }

    /// 面板收起时在“走路”切换条上提示路线还在。
    var routeChipSubtitle: String? {
        switch route.phase {
        case .inactive: return nil
        case .preparing: return "已设路线"
        case .playing: return "进行中"
        case .paused: return "已暂停"
        case .finished: return "已走完"
        }
    }

    var routeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoutePlaybackPanel(
                route: route,
                clock: route.clock,
                currentPair: currentSelectionPair,
                onExit: requestExitRoute,
                onSave: promptSaveRoute,
                onOpenSaved: openSavedRoutes,
                embedded: true
            )
            routePlaybackSpoofControls
        }
    }

    @ViewBuilder
    var routePlaybackSpoofControls: some View {
        if spoofState != .idle {
            HStack(spacing: 10) {
                Button(action: handleMainButtonTap) {
                    HStack(spacing: 6) {
                        if spoofState == .verifying {
                            ProgressView().tint(.white)
                        }
                        Text(routePlaybackButtonTitle)
                    }
                    .frame(maxWidth: needsSwitchButton ? nil : .infinity)
                    .frame(minWidth: needsSwitchButton ? 56 : nil)
                    .padding(.horizontal, needsSwitchButton ? 12 : 0)
                }
                .buttonStyle(PrimaryActionStyle(tint: buttonColor, compact: true))
                .disabled(spoofState == .verifying)

                if needsSwitchButton {
                    Button(action: { beginLocationOperation() }) {
                        Label("切换到此处", systemImage: "arrow.triangle.swap")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    }
                    .background(.blue, in: RoundedRectangle(cornerRadius: AppRadius.control))
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var routePlaybackButtonTitle: String {
        if spoofState == .active, needsSwitchButton { return "关闭" }
        if spoofState == .active { return "停止虚拟定位" }
        return buttonTitle
    }

    func playRoute() {
        bindRoutePlayback()
        if UIPreview.isEnabled() {
            playRouteInPreview()
            return
        }
        if locationUseBlock != nil { return }
        if routeUsesDeveloperTunnel {
            playRouteThroughDeveloperTunnel()
        } else {
            playRouteThroughSpoofSession()
        }
    }

    /// 开发者模式只推进本地播放和灵动岛，不写系统定位。
    private func playRouteInPreview() {
        if route.phase == .paused {
            route.resume()
            return
        }
        guard route.start != nil, route.canPlay else { return }
        route.requestPlay()
        route.noteActivated()
    }

    /// 开发者隧道：先确认隧道和配对文件就绪，再把起点推进系统定位。
    private func playRouteThroughDeveloperTunnel() {
        routeLocation.refresh()
        if route.phase == .paused {
            guard beginRouteLocation() else { return }
            route.resume()
            return
        }
        guard let start = route.start, route.canPlay else { return }
        guard beginRouteLocation() else { return }
        route.requestPlay()
        Task { @MainActor in
            await activateRouteStart(route.current ?? start)
        }
    }

    /// 本机代理和第三方模式：路线和定点走同一条写入通道。
    /// 虚拟定位尚未开启时先用起点开启，开启成功后由 handleRouteSpoofStateChange 启动播放。
    private func playRouteThroughSpoofSession() {
        if spoofState == .verifying { return }
        RouteLocationLaunch.prepareForSpoofSession(route)
        if route.phase == .paused {
            route.resume()
            return
        }
        guard let start = route.start, route.canPlay else { return }
        route.requestPlay()
        if spoofState == .active {
            Task { @MainActor in
                await activateRouteStart(route.current ?? start)
            }
            return
        }
        let startFavorite = FavoriteLocation(
            name: "路线",
            coordinatePair: start,
            accuracy: LocationAccuracyStore.shared.meters
        )
        beginLocationOperation(target: startFavorite)
    }

    private func activateRouteStart(_ pair: CoordinatePair) async {
        let applied = await applyRouteCoordinate(pair)
        if applied {
            route.noteActivated()
        } else {
            route.cancelWaiting()
            route.statusMessage = route.pushFailureMessage
        }
    }

    func beginRouteLocation() -> Bool {
        guard RouteLocationLaunch.prepare(route, readiness: routeLocation.readiness) == nil else {
            showRouteLocationSetup = true
            return false
        }
        return true
    }

    func applyRouteCoordinate(_ pair: CoordinatePair) async -> Bool {
        if UIPreview.isEnabled() { return true }
        guard routeUsesDeveloperTunnel else {
            return await session.writeRoute(pair, offsetMeters: route.offsetMeters)
        }
        let coordinate = RoutePlayback.offset(pair, radiusMeters: route.offsetMeters).wgs84
        if let failure = await routeLocation.set(latitude: coordinate.latitude, longitude: coordinate.longitude) {
            route.pushFailureMessage = failure.message
            return false
        }
        return true
    }

    /// 只有开发者隧道会占用系统定位。路线结束后，定点仍开启就回到定点，否则清掉模拟。
    func clearRouteLocationIfNeeded(from previous: RoutePhase, to next: RoutePhase) {
        guard !UIPreview.isEnabled(),
              routeUsesDeveloperTunnel,
              RouteLocationStop.shouldClearSimulation(from: previous, to: next) else { return }
        if spoofState == .active, let latitude = activeSpoofLat, let longitude = activeSpoofLon {
            Task { _ = await routeLocation.set(latitude: latitude, longitude: longitude) }
            return
        }
        Task { await routeLocation.clear() }
    }

    func handleRouteSpoofStateChange(_ state: SpoofState) {
        if routeUsesDeveloperTunnel {
            if state == .idle, route.waitingForActivation {
                route.cancelWaiting()
            }
            return
        }
        switch state {
        case .active:
            if route.waitingForActivation {
                route.noteActivated()
            }
        case .idle:
            if route.waitingForActivation {
                route.cancelWaiting()
            }
            route.pause()
        case .verifying:
            break
        }
    }
}

struct HomePeekCaption: View {
    @ObservedObject var route: RoutePlaybackController
    @ObservedObject var clock: RoutePlaybackClock
    let showsRoute: Bool

    var body: some View {
        if let text = caption {
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var caption: String? {
        showsRoute ? routeCaption : backgroundCaption
    }

    private var routeCaption: String? {
        switch route.phase {
        case .playing, .paused:
            _ = clock.progress
            return RoutePlayback.formattedRemaining(
                meters: route.remainingMeters,
                speedMetersPerSecond: route.speedMetersPerSecond
            )
        case .finished:
            return "已走完"
        case .preparing:
            if route.isRouting { return "正在规划路线" }
            if route.canPlay { return RoutePlayback.formattedDistance(route.distanceMeters) }
            return "先设起点和终点"
        case .inactive:
            return nil
        }
    }

    private var backgroundCaption: String? {
        switch route.phase {
        case .inactive: return nil
        case .preparing: return "已设路线"
        case .playing: return "进行中"
        case .paused: return "已暂停"
        case .finished: return "已走完"
        }
    }
}

extension MapHomeView {
    func pauseRouteIfLocationBlocked() {
        guard locationUseBlock != nil else { return }
        route.pause()
        if route.waitingForActivation {
            route.cancelWaiting()
        }
    }
}
