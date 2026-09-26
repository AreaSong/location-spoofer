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
        RouteActivityBridge.handler = { action in
            handleIslandAction(action)
        }
        RouteActivityBridge.expirationHandler = { action in
            noteIslandRejection(action, "这个操作已过期，请再试一次。")
        }
        RouteActivityBridge.drainPending()
        syncRouteActivity(clearStale: true)
    }

    func handleIslandAction(_ action: String) {
        let context = islandCommandContext()
        let concrete = IslandCommandRouter.resolve(action, context: context)
        switch IslandCommandRouter.decide(concrete, context: context) {
        case .run:
            RuntimeLogger.info("RouteLiveActivity", "action", "执行灵动岛动作", details: ["action": concrete])
            performIslandCommand(concrete)
        case .alreadySatisfied:
            RuntimeLogger.info("RouteLiveActivity", "action", "灵动岛动作已经生效", details: ["action": concrete])
            syncRouteActivity()
        case .leaveCurrent:
            RuntimeLogger.info("RouteLiveActivity", "action", "保留当前异常状态", details: ["action": concrete])
        case .unavailable(let message):
            RuntimeLogger.warning(
                "RouteLiveActivity",
                "action",
                "灵动岛动作不可用",
                details: ["action": concrete, "reason": message]
            )
            guard shouldRememberIslandRejection(concrete) else { return }
            noteIslandRejection(concrete, message)
        }
    }

    /// 路线还占着定位时，拒绝定点动作不能写成定点失败，否则路线结束后会把正常定位显示成操作失败。
    private func shouldRememberIslandRejection(_ action: String) -> Bool {
        switch action {
        case "stopSpoof", "switchHere", "begin":
            return route.phase != .playing && route.phase != .paused && !route.waitingForActivation
        default:
            return true
        }
    }

    private func islandCommandContext() -> IslandCommandContext {
        let retryCommand = routeCommand.failedCommand.isEmpty ? spotRetryCommand : routeCommand.failedCommand
        let block = locationUseBlock
        return IslandCommandContext(
            routePhase: route.phase,
            interruption: route.interruption,
            statusMessage: route.statusMessage,
            waitingForActivation: route.waitingForActivation,
            spoofState: spoofState,
            needsSwitch: needsSwitchButton,
            spotStopPending: spotStopPending,
            spotSwitchPending: spotSwitchPending,
            retryCommand: retryCommand,
            locationBlocked: block != nil,
            locationBlockMessage: block?.message ?? ""
        )
    }

    private func performIslandCommand(_ action: String) {
        switch action {
        case "pause":
            route.pause()
            routeCommand = RouteCommandTracking.afterAttempt(
                command: "pause",
                phase: route.phase,
                interruption: route.interruption,
                waitingForActivation: route.waitingForActivation,
                statusMessage: route.statusMessage
            )
            syncRouteActivity()
        case "resume":
            playRoute()
            noteRouteAttempt("resume")
        case "play":
            playRoute()
            noteRouteAttempt("play")
        case "begin", "switchHere":
            beginLocationOperation()
        case "stopRoute":
            // 只停播放。虚拟定位留给定点岛上的「停止虚拟定位」。
            route.stopPlaybackKeepingLocation()
            routeCommand = RouteCommandTracking.afterAttempt(
                command: "stopRoute",
                phase: route.phase,
                interruption: route.interruption,
                waitingForActivation: route.waitingForActivation,
                statusMessage: route.statusMessage
            )
            syncRouteActivity()
        case "stopSpoof":
            stopSpoofing()
        case "openApp":
            break
        default:
            noteIslandRejection(action, "不支持这个操作。")
        }
    }

    private func noteIslandRejection(_ action: String, _ message: String) {
        switch action {
        case "pause", "resume", "play", "stopRoute":
            routeCommand = RouteCommandTracking(commandFailed: true, failedCommand: action, errorText: message)
        case "stopSpoof", "switchHere", "begin":
            noteSpotActionFailure(message: message, command: action)
        default:
            if spoofState != .idle {
                noteSpotActionFailure(message: message, command: "begin")
            } else {
                routeCommand = RouteCommandTracking(commandFailed: true, failedCommand: "play", errorText: message)
            }
        }
        syncRouteActivity()
    }

    private func noteRouteAttempt(_ command: String) {
        routeCommand = RouteCommandTracking.afterAttempt(
            command: command,
            phase: route.phase,
            interruption: route.interruption,
            waitingForActivation: route.waitingForActivation,
            statusMessage: route.statusMessage
        )
        syncRouteActivity()
    }

    func syncRouteActivity(clearStale: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        routeCommand = routeCommand.reconcile(
            phase: route.phase,
            interruption: route.interruption,
            waitingForActivation: route.waitingForActivation
        )
        let travelSymbol = route.travelMode == .bike ? "bicycle" : "figure.walk"
        let routeName = route.editingSavedRoute?.name ?? route.travelMode.displayName
        let confirmStopped = route.phase == .preparing
            && route.interruption != .activationFailed
            && route.statusMessage == RouteActivitySync.stoppedMessage
        let statusMessage = routeCommand.commandFailed ? routeCommand.errorText : route.statusMessage
        let routeSnapshot = RouteActivitySync.snapshot(
            phase: route.phase,
            interruption: route.interruption,
            statusMessage: statusMessage,
            routeName: routeName,
            remainingMeters: route.remainingMeters,
            speedMetersPerSecond: route.speedMetersPerSecond,
            progress: route.progress,
            symbolName: travelSymbol,
            isRetrying: routeCommand.isRetrying,
            commandFailed: routeCommand.commandFailed,
            failedCommand: routeCommand.failedCommand,
            confirmStopped: confirmStopped
        )
        let liveRoute = routeSnapshotForIsland(routeSnapshot)
        let spotStopped = spoofState == .idle
            && spotStoppedConfirmUntil.map { $0 > Date() } == true
        let spotSnapshot = liveRoute == nil ? SpotActivitySync.snapshot(
            isVerifying: spoofState == .verifying,
            isActive: spoofState == .active,
            needsSwitch: needsSwitchButton,
            failed: spotIslandFailed,
            placeName: mapState.displayName ?? "当前选点",
            coordinateStandard: CoordinateConverter.currentMapCoordinateSystem.rawValue,
            accuracyMeters: LocationAccuracyStore.shared.meters,
            isSwitching: spotSwitchPending,
            isStopping: spotStopPending,
            isStopped: spotStopped,
            actionFailed: spotActionFailed,
            errorText: spotFailureMessage,
            retryCommand: spotRetryCommand
        ) : nil
        Task {
            let keepForRecovery = route.phase == .inactive && route.sessionStore.load() != nil
            if clearStale {
                await RouteLiveActivityCenter.shared.reconcileOnLaunch(hasRecoverableSession: keepForRecovery)
            }
            await RouteLiveActivityCenter.shared.sync(
                route: liveRoute,
                spot: spotSnapshot,
                keepForRecovery: keepForRecovery
            )
        }
    }

    /// 已停止先短确认。时间一到且定点仍生效，就不再发路线快照，让定点布局接上。
    private func routeSnapshotForIsland(_ snapshot: RouteActivitySnapshot?) -> RouteActivitySnapshot? {
        guard snapshot?.phaseKey == .stopped else {
            routeStoppedConfirmUntil = nil
            return snapshot
        }
        if routeStoppedConfirmUntil == nil {
            let until = Date().addingTimeInterval(RouteActivitySync.stoppedConfirmInterval)
            routeStoppedConfirmUntil = until
            Task { @MainActor in
                let delay = until.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                syncRouteActivity()
            }
        }
        if RouteActivitySync.suppressStoppedRoute(
            confirmUntil: routeStoppedConfirmUntil,
            now: Date(),
            spotStillActive: spoofState == .active
        ) {
            return nil
        }
        return snapshot
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
        let pendingWrite = route.exit()
        showsRoutePanel = false
        settleRouteSimulation(after: pendingWrite, from: previous)
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
        if routeKeepsRunningWhileSpotShown { return false }
        return showsRoutePanelActive ? routePeekDisabled : spoofState == .verifying
    }

    var homePeekOpensDetail: Bool {
        showsRoutePanelActive && routePeekOpensDetail
    }

    var routePeekTitle: String {
        switch route.phase {
        case .playing: return "暂停"
        case .paused: return "继续"
        case .preparing where route.interruption == .activationFailed && route.end != nil:
            return "重试"
        case .preparing where route.start == nil: return "设为起点"
        case .preparing: return "设为终点"
        default: return "开始走"
        }
    }

    var routePeekOpensDetail: Bool { false }

    /// 面板收起后路线仍占着定位：播放、暂停，或正在开启。
    var routeKeepsRunningWhileSpotShown: Bool {
        guard !showsRoutePanel else { return false }
        return route.phase == .playing || route.phase == .paused || route.waitingForActivation
    }

    var routePeekDisabled: Bool {
        if route.phase == .playing { return false }
        if route.phase == .preparing, route.start == nil || route.end == nil || !route.canPlay {
            return route.isRouting
        }
        return !route.canPlay || route.waitingForActivation || route.isRouting
    }

    func handlePeekTap() {
        guard showsRoutePanelActive else {
            if routeKeepsRunningWhileSpotShown {
                showsRoutePanel = true
                return
            }
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
                onRestart: { playRoute(fromStart: true) },
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

    func playRoute(fromStart: Bool = false) {
        bindRoutePlayback()
        if fromStart {
            route.resetProgressForRestart()
        }
        if UIPreview.isEnabled() {
            playRouteInPreview()
            return
        }
        if locationUseBlock != nil {
            route.markPausedLocationBlocked()
            return
        }
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
        route.beginActivation()
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
            route.beginActivation()
            return
        }
        let startFavorite = FavoriteLocation(
            name: "路线",
            coordinatePair: start,
            accuracy: LocationAccuracyStore.shared.meters
        )
        beginLocationOperation(target: startFavorite)
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
            if failure == .superseded { return false }
            route.pushFailureMessage = failure.message
            return false
        }
        return true
    }

    /// 只有开发者隧道会占用系统定位。路线结束后，定点仍开启就回到定点，否则清掉模拟。
    /// 开启等待期间退出时，先等已经发出的起点写入结束，再清，避免清完又被旧任务写回。
    func settleRouteSimulation(after pendingWrite: Task<Void, Never>?, from previous: RoutePhase) {
        guard RouteLocationStop.shouldClearSimulation(
            from: previous,
            to: route.phase,
            activationWritePending: pendingWrite != nil
        ) else { return }
        Task { @MainActor in
            await pendingWrite?.value
            await restoreOrClearRouteSimulation()
        }
    }

    func clearRouteLocationIfNeeded(from previous: RoutePhase, to next: RoutePhase) {
        guard RouteLocationStop.shouldClearSimulation(from: previous, to: next) else { return }
        Task { await restoreOrClearRouteSimulation() }
    }

    private func restoreOrClearRouteSimulation() async {
        guard !UIPreview.isEnabled(), routeUsesDeveloperTunnel else { return }
        if spoofState == .active, let latitude = activeSpoofLat, let longitude = activeSpoofLon {
            _ = await routeLocation.set(latitude: latitude, longitude: longitude)
            return
        }
        if let failure = await routeLocation.clear(), failure != .superseded {
            route.statusMessage = failure.message
        }
    }

    func handleRouteSpoofStateChange(_ state: SpoofState) {
        if routeUsesDeveloperTunnel {
            if state == .idle, route.waitingForActivation {
                settleRouteSimulation(after: route.cancelWaiting(), from: .preparing)
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
                settleRouteSimulation(after: route.cancelWaiting(), from: .preparing)
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
        if route.phase == .playing {
            route.pauseBecauseLocationBlocked()
        }
        if route.waitingForActivation {
            let pendingWrite = route.cancelWaiting()
            route.markActivationFailed(RouteActivitySync.locationBlockedMessage)
            settleRouteSimulation(after: pendingWrite, from: .preparing)
        }
    }
}
