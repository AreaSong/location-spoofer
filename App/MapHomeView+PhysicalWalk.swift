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

    var physicalWalkIslandSignature: String {
        guard physicalWalk.isTracking else { return "off" }
        let meters = Int(physicalWalk.movedMeters.rounded())
        let heading = physicalWalk.activeHeadingDegrees.map {
            PhysicalWalkHeadingLock.compassName($0)
        } ?? ""
        return "\(meters)|\(heading)"
    }

    /// 当前定位蓝点：定点后用已写入的虚拟坐标；未定点时用实时定位，保证进软件就有扇形。
    var walkPuckMapCoordinate: CLLocationCoordinate2D? {
        WalkPuckMapPlacement.coordinate(
            spoofActive: spoofState == .active,
            writtenLatitude: session.writtenLatitude,
            writtenLongitude: session.writtenLongitude,
            liveLatitude: physicalWalk.currentLatitude,
            liveLongitude: physicalWalk.currentLongitude,
            realtimeCoordinate: mapState.realtimeCoordinate,
            mapSystem: displayedMapCoordinateSystem
        )
    }

    func bindPhysicalWalk() {
        physicalWalk.ignoresWriteGate = runtimeMode.mode == .developerTunnel
        physicalWalk.strideMeters = { physicalWalkStore.strideMeters }
        physicalWalk.applyCoordinate = { pair in
            await applyPhysicalWalkCoordinate(pair)
        }
        physicalWalk.onFailure = { message in
            physicalWalkStore.noteFailure(message)
        }
        physicalWalk.applyPersistedInitial(physicalWalkStore.initialHeadingDegrees)
        physicalWalk.setCustomHeadingEnabled(physicalWalkStore.isCustomHeadingEnabled)
    }

    func syncPhysicalWalk() {
        bindPhysicalWalk()
        claimPhysicalWalkFromRoute()
        if shouldTrackPhysicalWalk {
            startPhysicalWalkIfNeeded()
        } else if physicalWalk.isTracking {
            physicalWalk.stop()
        }
        physicalWalk.startHeadingPreview()
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
            Toggle("初始指向", isOn: customHeadingBinding)
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                Button("−15°") {
                    nudgeInitialHeading(by: -15)
                }
                .buttonStyle(CapsuleChipStyle())
                .disabled(!store.isCustomHeadingEnabled)
                .accessibilityLabel("初始朝向减少 15 度")
                Text(PhysicalWalkHeadingLock.labeledDegrees(controller.activeHeadingDegrees ?? 0))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("真实走动", isOn: enabledBinding)
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                Button("+15°") {
                    nudgeInitialHeading(by: 15)
                }
                .buttonStyle(CapsuleChipStyle())
                .disabled(!store.isCustomHeadingEnabled)
                .accessibilityLabel("初始朝向增加 15 度")
            }
            Slider(value: headingBinding, in: 0...359, step: 1)
                .disabled(!store.isCustomHeadingEnabled)
                .accessibilityLabel("初始朝向")
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "计步兜底步长 %.2f 米", store.strideMeters))
                    .font(.caption.weight(.semibold))
                Slider(
                    value: strideBinding,
                    in: PhysicalWalkDisplacement.minimumStrideMeters...PhysicalWalkDisplacement.maximumStrideMeters,
                    step: 0.02
                )
                .accessibilityLabel("计步兜底步长")
                Text("计步器没有距离时，按这个步长把步数换成米。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        } else if !store.isEnabled {
            Text("打开真实走动后，走路才会移动坐标")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !store.isCustomHeadingEnabled {
            Text("扇形跟系统地图朝向一致")
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

    private var customHeadingBinding: Binding<Bool> {
        Binding(
            get: { store.isCustomHeadingEnabled },
            set: {
                store.setCustomHeadingEnabled($0)
                controller.setCustomHeadingEnabled($0)
            }
        )
    }

    private var headingBinding: Binding<Double> {
        Binding(
            get: { controller.initialHeadingDegrees },
            set: { persistInitialHeading($0) }
        )
    }

    private var strideBinding: Binding<Double> {
        Binding(
            get: { store.strideMeters },
            set: { store.setStrideMeters($0) }
        )
    }

    private func nudgeInitialHeading(by delta: Double) {
        controller.rotateLockedHeading(by: delta)
        store.setInitialHeadingDegrees(controller.initialHeadingDegrees)
    }

    private func persistInitialHeading(_ degrees: Double) {
        controller.lockHeading(degrees: degrees)
        store.setInitialHeadingDegrees(controller.initialHeadingDegrees)
    }
}
