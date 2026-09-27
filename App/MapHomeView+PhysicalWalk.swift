import CoreLocation
import SwiftUI

extension MapHomeView {
    var physicalWalkPeekText: String? {
        guard physicalWalk.isTracking else { return nil }
        switch physicalWalk.status {
        case .waitingForHeading:
            return "等待罗盘朝向"
        case .tracking:
            return "真实走动中"
        case .idle:
            return nil
        }
    }

    func bindPhysicalWalk() {
        physicalWalk.ignoresWriteGate = runtimeMode.mode == .developerTunnel
        physicalWalk.applyCoordinate = { pair in
            await applyPhysicalWalkCoordinate(pair)
        }
        physicalWalk.onFailure = { message in
            physicalWalkStore.noteFailure(message)
        }
    }

    func syncPhysicalWalk() {
        bindPhysicalWalk()
        claimPhysicalWalkFromRoute()
        if shouldTrackPhysicalWalk {
            startPhysicalWalkIfNeeded()
        } else {
            physicalWalk.stop()
        }
    }

    func handlePhysicalWalkRoutePhase(_ phase: RoutePhase) {
        if PhysicalWalkSession.shouldDisableForRoutePlayback(
            routePlaying: phase == .playing,
            routeWaiting: route.waitingForActivation
        ) {
            physicalWalkStore.setEnabled(false)
        }
        syncPhysicalWalk()
    }

    func stopPhysicalWalkForRoutePlayback() {
        physicalWalkStore.setEnabled(false)
        physicalWalk.stop()
    }

    func restartPhysicalWalkFromWrittenCoordinate() {
        physicalWalk.stop()
        syncPhysicalWalk()
    }

    private var shouldTrackPhysicalWalk: Bool {
        PhysicalWalkSession.shouldTrack(
            isEnabled: physicalWalkStore.isEnabled,
            spoofActive: spoofState == .active,
            routePlaying: route.phase == .playing,
            routeWaiting: route.waitingForActivation,
            preview: UIPreview.isEnabled(),
            useBlocked: locationUseBlock != nil
        )
    }

    private func claimPhysicalWalkFromRoute() {
        guard physicalWalkStore.isEnabled, spoofState == .active else { return }
        if route.phase == .playing {
            route.pause()
        }
        if route.waitingForActivation {
            settleRouteSimulation(after: route.cancelWaiting(), from: route.phase)
        }
    }

    private func startPhysicalWalkIfNeeded() {
        guard !physicalWalk.isTracking else { return }
        guard let latitude = session.writtenLatitude, let longitude = session.writtenLongitude else {
            return
        }
        physicalWalk.start(latitude: latitude, longitude: longitude)
    }

    private func applyPhysicalWalkCoordinate(_ pair: CoordinatePair) async -> Bool {
        let applied = await session.writeMoving(pair)
        if applied {
            applyPhysicalWalkMapSelection(pair)
        }
        return applied
    }

    private func applyPhysicalWalkMapSelection(_ pair: CoordinatePair) {
        let coordinate = pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
        mapState.selectMapTap(coordinate)
        cachedSelectionPair = pair
        LastCoordinateStore.save(coordinatePair: pair, zoomMeters: mapState.viewportMeters)
        favorites.select(nil)
    }
}
