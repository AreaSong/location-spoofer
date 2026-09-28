import CoreLocation
import SwiftUI

extension MapHomeView {
    var physicalWalkPeekText: String? {
        PhysicalWalkStatusCopy.peek(
            isEnabled: physicalWalkStore.isEnabled,
            spoofActive: spoofState == .active,
            isTracking: physicalWalk.isTracking,
            status: physicalWalk.status,
            movedMeters: physicalWalk.movedMeters,
            headingDegrees: physicalWalk.activeHeadingDegrees
        )
    }

    /// 当前已写入的虚拟坐标，转成地图标准后给蓝点扇形用。红钉仍表示地图中心选点。
    var walkPuckMapCoordinate: CLLocationCoordinate2D? {
        WalkPuckMapPlacement.coordinate(
            walkEnabled: physicalWalkStore.isEnabled,
            spoofActive: spoofState == .active,
            writtenLatitude: session.writtenLatitude,
            writtenLongitude: session.writtenLongitude,
            mapSystem: displayedMapCoordinateSystem
        )
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
        } else if physicalWalkStore.isEnabled {
            if physicalWalk.isTracking {
                physicalWalk.stop()
            }
            physicalWalk.startHeadingPreview()
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

struct PhysicalWalkHeadingControls: View {
    @ObservedObject var store: PhysicalWalkStore
    @ObservedObject var controller: PhysicalWalkController
    let spoofActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("−15°") {
                    controller.rotateLockedHeading(by: -15)
                }
                .buttonStyle(CapsuleChipStyle())
                .disabled(!store.isEnabled)
                .accessibilityLabel("朝向减少 15 度")
                Toggle("真实走动", isOn: enabledBinding)
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                Button("+15°") {
                    controller.rotateLockedHeading(by: 15)
                }
                .buttonStyle(CapsuleChipStyle())
                .disabled(!store.isEnabled)
                .accessibilityLabel("朝向增加 15 度")
            }
            Slider(value: headingBinding, in: 0...359, step: 1)
                .disabled(!store.isEnabled)
                .accessibilityLabel("朝向角度")
            walkHint
        }
    }

    @ViewBuilder
    private var walkHint: some View {
        if !store.lastFailureMessage.isEmpty {
            Text(store.lastFailureMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.isEnabled && !spoofActive {
            Text("先开启虚拟定位")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { store.setEnabled($0) }
        )
    }

    private var headingBinding: Binding<Double> {
        Binding(
            get: { controller.activeHeadingDegrees ?? 0 },
            set: { controller.lockHeading(degrees: $0) }
        )
    }
}
