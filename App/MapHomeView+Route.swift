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
        syncRouteSpoofCoordinate()
        route.exit()
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
        if locationUseBlock != nil { return false }
        let accuracy = LocationAccuracyStore.shared.meters
        let offsetMeters = route.offsetMeters
        if runtimeMode.mode == .thirdParty {
            let favorite = FavoriteLocation(
                name: "路线",
                coordinatePair: pair,
                accuracy: accuracy
            )
            do {
                _ = try await thirdPartyProxy.save(favorite, randomRadius: offsetMeters)
                runtimeFailure.clearThirdParty()
                return true
            } catch {
                RuntimeLogger.error(
                    "APP",
                    "ThirdPartyProxy",
                    "路线写入第三方坐标失败",
                    error: error,
                    details: [
                        "当前客户端": thirdPartyClient.selectedClient.name,
                        "原因": ThirdPartyProxyError.diagnosis(for: error).title
                    ]
                )
                return false
            }
        }
        let written = RoutePlayback.offset(pair, radiusMeters: offsetMeters)
        let wgs = written.wgs84
        return actions.updateSpoofedWGS84(
            latitude: wgs.latitude,
            longitude: wgs.longitude,
            accuracy: accuracy
        )
    }

    func syncRouteSpoofCoordinate() {
        guard route.phase != .inactive, let current = route.current else { return }
        activeSpoofLat = current.wgs84.latitude
        activeSpoofLon = current.wgs84.longitude
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
