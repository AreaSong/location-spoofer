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

struct PhysicalWalkSpotControl: View {
    @ObservedObject var store: PhysicalWalkStore
    @ObservedObject var controller: PhysicalWalkController
    let spoofActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("真实走动", isOn: enabledBinding)
            Text(detailText)
                .font(.caption)
                .foregroundStyle(store.lastFailureMessage.isEmpty ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            headingControls
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { store.setEnabled($0) }
        )
    }

    private var detailText: String {
        PhysicalWalkStatusCopy.detail(
            isEnabled: store.isEnabled,
            spoofActive: spoofActive,
            status: controller.status,
            movedMeters: controller.movedMeters,
            failureMessage: store.lastFailureMessage,
            headingDegrees: controller.activeHeadingDegrees,
            headingLocked: controller.headingMode.isLocked
        )
    }

    private var headingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("跟随罗盘") { controller.followCompass() }
                    .buttonStyle(CapsuleChipStyle(tint: controller.headingMode == .followCompass ? .accentColor : nil))
                    .accessibilityLabel("跟随罗盘朝向")
                Button {
                    controller.rotateLockedHeading(by: -15)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(CapsuleChipStyle())
                .accessibilityLabel("箭头向左偏 15 度")
                Button {
                    controller.rotateLockedHeading(by: 15)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(CapsuleChipStyle())
                .accessibilityLabel("箭头向右偏 15 度")
            }
            HStack(spacing: 8) {
                ForEach(PhysicalWalkHeadingLock.cardinals, id: \.title) { item in
                    Button(item.title) { controller.lockHeading(degrees: item.degrees) }
                        .buttonStyle(CapsuleChipStyle(tint: isSelectedCardinal(item.degrees) ? .accentColor : nil))
                        .accessibilityLabel("朝\(item.title)")
                }
            }
        }
        .disabled(!store.isEnabled)
        .opacity(store.isEnabled ? 1 : 0.45)
    }

    private func isSelectedCardinal(_ degrees: Double) -> Bool {
        guard case let .locked(locked) = controller.headingMode else { return false }
        return abs(PhysicalWalkHeadingLock.normalized(locked - degrees)) < 0.01
            || abs(PhysicalWalkHeadingLock.normalized(locked - degrees) - 360) < 0.01
    }
}
