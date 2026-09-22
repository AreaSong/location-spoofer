import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    @MainActor
    func bindRoutePlayback() {
        route.applyCoordinate = { pair in
            await applyRouteCoordinate(pair)
        }
    }

    func enterRoute() {
        if locationUseBlock != nil { return }
        if route.phase == .inactive {
            route.enter()
        }
    }

    func openSavedRoutes() {
        if locationUseBlock != nil { return }
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
        route.exit()
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
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: needsSwitchButton ? nil : .infinity)
                    .frame(minWidth: needsSwitchButton ? 56 : nil)
                    .padding(.vertical, 12)
                    .padding(.horizontal, needsSwitchButton ? 12 : 0)
                }
                .background(buttonColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
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
                    .background(.blue, in: RoundedRectangle(cornerRadius: 14))
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
        if spoofState == .verifying { return }
        if route.phase == .paused {
            route.resume()
            return
        }
        guard let start = route.start, route.canPlay else { return }
        route.requestPlay()
        if spoofState == .active {
            Task { @MainActor in
                let applied = await applyRouteCoordinate(route.current ?? start)
                if applied {
                    route.noteActivated()
                } else {
                    route.cancelWaiting()
                }
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

    func applyRouteCoordinate(_ pair: CoordinatePair) async -> Bool {
        await session.writeRoute(pair, offsetMeters: route.offsetMeters)
    }

    func handleRouteSpoofStateChange(_ state: SpoofState) {
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
