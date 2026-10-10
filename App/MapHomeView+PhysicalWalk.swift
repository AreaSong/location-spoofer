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
        session.bindPhysicalWalk(physicalWalk) { pair in
            applyPhysicalWalkMapSelection(pair)
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
            useBlocked: locationUseBlock != nil || session.writesSuspended
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
    @State private var showsInfo = false
    @State private var barWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WalkBarWidthKey.self, value: geometry.size.width)
                    }
                }
            if showsInfo {
                infoTip
            }
            if !store.lastFailureMessage.isEmpty {
                Text(store.lastFailureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isEnabled {
                enabledRows
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: store.isEnabled)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: store.isCustomHeadingEnabled)
        .onPreferenceChange(WalkBarWidthKey.self) { if $0 > 1 { barWidth = $0 } }
        .task(id: showsInfo) {
            guard showsInfo else { return }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            showsInfo = false
        }
    }

    private var panelWidth: CGFloat {
        barWidth > 1 ? barWidth : 220
    }

    private var enabledRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.isCustomHeadingEnabled {
                headingAdjustment
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            strideRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "figure.walk.motion")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("真实走动")
                .font(.subheadline.weight(.semibold))
                .fixedSize()
                .layoutPriority(2)
                .accessibilityHidden(true)
            infoButton
            WalkCompactToggle(title: "开启", isOn: enabledBinding, accessibilityLabel: "真实走动")
            if store.isEnabled {
                WalkCompactToggle(title: "初始指向", isOn: customHeadingBinding, accessibilityLabel: "初始指向")
            }
        }
    }

    private var infoButton: some View {
        Button {
            showsInfo.toggle()
        } label: {
            Image(systemName: showsInfo ? "info.circle.fill" : "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(showsInfo ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("真实走动说明")
        .accessibilityValue(infoText)
        .accessibilityIdentifier("home.walk.info")
    }

    private var infoTip: some View {
        Text(infoText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: panelWidth, alignment: .leading)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }

    private var infoText: String {
        PhysicalWalkStatusCopy.homePanelInfo(
            isEnabled: store.isEnabled,
            spoofActive: spoofActive,
            status: controller.status,
            movedMeters: controller.movedMeters,
            failureMessage: store.lastFailureMessage,
            headingDegrees: controller.activeHeadingDegrees,
            headingLocked: store.isCustomHeadingEnabled
        )
    }

    private var headingAdjustment: some View {
        Color.clear
            .frame(width: panelWidth, height: 30)
            .overlay {
                HStack(spacing: 3) {
                    Image(systemName: "safari")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 14)
                    Text(PhysicalWalkHeadingLock.labeledDegrees(controller.activeHeadingDegrees))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 58, height: 22)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Button("−15°") {
                        Haptics.selection()
                        nudgeInitialHeading(by: -15)
                    }
                    .font(.caption2.weight(.medium))
                    .frame(width: 32, height: 26)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .buttonStyle(HomeInteractiveButtonStyle())
                    .accessibilityLabel("初始朝向减少 15 度")
                    Slider(value: headingBinding, in: 0...359, step: 1)
                        .tint(Color.accentColor)
                        .layoutPriority(1)
                        .accessibilityLabel("初始朝向")
                    Button("+15°") {
                        Haptics.selection()
                        nudgeInitialHeading(by: 15)
                    }
                    .font(.caption2.weight(.medium))
                    .frame(width: 32, height: 26)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .buttonStyle(HomeInteractiveButtonStyle())
                    .accessibilityLabel("初始朝向增加 15 度")
                }
            }
    }

    private var strideRow: some View {
        Color.clear
            .frame(width: panelWidth, height: 30)
            .overlay {
                HStack(spacing: 4) {
                    Image(systemName: "shoeprints.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 14)
                    Slider(
                        value: strideBinding,
                        in: PhysicalWalkDisplacement.minimumStrideMeters...PhysicalWalkDisplacement.maximumStrideMeters,
                        step: 0.02
                    )
                    .tint(Color.accentColor)
                    .accessibilityLabel("计步兜底步长")
                    Text(String(format: "%.2f米", store.strideMeters))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .frame(minWidth: 46, alignment: .trailing)
                }
            }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { newValue in
                Haptics.selection()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    store.setEnabled(newValue)
                }
            }
        )
    }

    private var customHeadingBinding: Binding<Bool> {
        Binding(
            get: { store.isCustomHeadingEnabled },
            set: { newValue in
                Haptics.selection()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    store.setCustomHeadingEnabled(newValue)
                    controller.setCustomHeadingEnabled(newValue)
                }
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
        let normalized = PhysicalWalkHeadingLock.normalized(degrees)
        guard controller.initialHeadingDegrees != normalized else { return }
        controller.lockHeading(degrees: normalized)
        store.setInitialHeadingDegrees(normalized)
    }
}

private enum WalkSwitchLayout {
    static let scale: CGFloat = 0.7
    static let width: CGFloat = 44
    static let height: CGFloat = 22
}

private struct WalkCompactToggle: View {
    let title: String
    @Binding var isOn: Bool
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .scaleEffect(WalkSwitchLayout.scale)
                .frame(width: WalkSwitchLayout.width, height: WalkSwitchLayout.height)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}

private enum WalkBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
