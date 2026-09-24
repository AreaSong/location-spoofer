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

    /// 面板收起时在“走路”切换条上提示路线还在。
    var routeChipSubtitle: String? {
        switch route.phase {
        case .inactive: return nil
        case .preparing: return "已设路线"
        case .playing: return "播放中"
        case .paused: return "已暂停"
        case .finished: return "已走完"
        }
    }

    var routeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoutePlaybackPanel(
                route: route,
                clock: route.clock,
                currentPair: currentSelectionPair,
                onPlay: playRoute,
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
                .buttonStyle(PrimaryActionStyle(tint: buttonColor))
                .disabled(spoofState == .verifying)

                if needsSwitchButton {
                    Button(action: { beginLocationOperation() }) {
                        Label("切换到此处", systemImage: "arrow.triangle.swap")
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
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
        if locationUseBlock != nil { return }
        if routeUsesDeveloperTunnel {
            playRouteThroughDeveloperTunnel()
        } else {
            playRouteThroughSpoofSession()
        }
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
        guard routeUsesDeveloperTunnel,
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

    func pauseRouteIfLocationBlocked() {
        guard locationUseBlock != nil else { return }
        route.pause()
        if route.waitingForActivation {
            route.cancelWaiting()
        }
    }
}
