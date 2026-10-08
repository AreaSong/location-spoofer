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
            let cleared = routeCommand.clearingSatisfied(concrete)
            if cleared != routeCommand {
                routeCommand = cleared
            }
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
        if IslandFavoriteCommand.favoriteID(from: action) != nil {
            return route.phase != .playing && route.phase != .paused && !route.waitingForActivation
        }
        switch action {
        case "stopSpoof", "switchHere", "begin":
            return route.phase != .playing && route.phase != .paused && !route.waitingForActivation
        case "stopWalk":
            return true
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
            locationBlockMessage: block?.message ?? "",
            physicalWalkTracking: physicalWalk.isTracking
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
        case "resume", "play":
            performRoutePlayback(action)
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
        case "stopWalk":
            physicalWalkStore.setEnabled(false)
            physicalWalk.stop()
            syncRouteActivity()
        case "cycleSpeed":
            route.setSpeedKilometersPerHour(
                RouteSpeedPreset.nextKilometersPerHour(
                    after: route.speedKilometersPerHour,
                    mode: route.travelMode
                )
            )
            syncRouteActivity()
        case "openApp":
            break
        default:
            if let favoriteID = IslandFavoriteCommand.favoriteID(from: action) {
                performSwitchFavorite(favoriteID, action: action)
                return
            }
            noteIslandRejection(action, "不支持这个操作。")
        }
    }

    private func performSwitchFavorite(_ id: UUID, action: String) {
        guard let favorite = favorites.favorites.first(where: { $0.id == id }) else {
            noteIslandRejection(action, "这个收藏点已经不在了。")
            return
        }
        IslandFavoriteShortcuts.performSwitch(to: favorite, action: action) { target in
            select(target)
            beginLocationOperation(target: target)
        } reject: { command, message in
            noteIslandRejection(command, message)
        }
    }

    private func performRoutePlayback(_ command: String) {
        if RoutePlaybackDeferral.waitsForSpotVerification(
            isVerifying: spoofState == .verifying,
            usesDeveloperTunnel: routeUsesDeveloperTunnel
        ) {
            syncRouteActivity()
            return
        }
        playRoute()
        noteRouteAttempt(command)
    }

    private func noteIslandRejection(_ action: String, _ message: String) {
        switch action {
        case "pause", "resume", "play", "stopRoute", "cycleSpeed":
            let updated = routeRejection(action, message)
            guard updated != routeCommand else { return }
            routeCommand = updated
        case "stopSpoof", "switchHere", "begin":
            noteSpotActionFailure(message: message, command: action)
        case "stopWalk":
            noteSpotActionFailure(message: message, command: action)
        default:
            if IslandFavoriteCommand.favoriteID(from: action) != nil {
                noteSpotActionFailure(message: message, command: action)
            } else if spoofState != .idle {
                noteSpotActionFailure(message: message, command: "begin")
            } else {
                let updated = routeRejection("play", message)
                guard updated != routeCommand else { return }
                routeCommand = updated
            }
        }
        syncRouteActivity()
    }

    private func routeRejection(_ action: String, _ message: String) -> RouteCommandTracking {
        RouteCommandTracking.rejectionResult(
            current: routeCommand,
            action: action,
            message: message,
            phase: route.phase,
            interruption: route.interruption,
            waitingForActivation: route.waitingForActivation
        )
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

    func syncRouteActivity(clearStale: Bool = false, retryCreation: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        routeCommand = routeCommand.reconcile(
            phase: route.phase,
            interruption: route.interruption,
            waitingForActivation: route.waitingForActivation
        )
        let travelSymbol = route.travelMode.symbolName
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
            confirmStopped: confirmStopped,
            travelMode: route.travelMode
        )
        let liveRoute = routeSnapshotForIsland(routeSnapshot)
        let shortcutItems = IslandFavoriteShortcuts.pick(
            from: favorites.displayedFavorites,
            selectedID: favorites.selectedFavoriteID,
            writtenLatitude: session.switchLatitude,
            writtenLongitude: session.switchLongitude,
            currentSelection: currentSelectionPair,
            needsSwitch: needsSwitchButton
        ).map { favorite in
            (
                action: IslandFavoriteCommand.action(for: favorite.id),
                title: SpotActivitySync.islandPlaceName(favorite.name)
            )
        }
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
            retryCommand: spotRetryCommand,
            shortcuts: shortcutItems,
            isPhysicalWalk: physicalWalk.isTracking,
            walkMovedMeters: physicalWalk.movedMeters,
            walkHeadingDegrees: physicalWalk.activeHeadingDegrees
        ) : nil
        Task {
            let keepForRecovery = route.phase == .inactive && route.sessionStore.load() != nil
            if clearStale {
                await RouteLiveActivityCenter.shared.reconcileOnLaunch(hasRecoverableSession: keepForRecovery)
            }
            await RouteLiveActivityCenter.shared.sync(
                route: liveRoute,
                spot: spotSnapshot,
                keepForRecovery: keepForRecovery,
                retryCreation: retryCreation
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
        session.bindRoutePlayback(route, preview: UIPreview.isEnabled()) { pair in
            mapState.selectMapTap(pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem))
            syncRouteActivity()
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
        do {
            let stored = try savedRoutes.save(snapshot)
            route.noteSaved(stored)
        } catch {
            route.statusMessage = "路线保存失败，请重试：\(error.localizedDescription)"
            return
        }
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
        if routeKeepsRunningWhileSpotShown { return .orange }
        if needsSwitchButton { return .blue }
        return buttonColor
    }

    var homePeekDisabled: Bool {
        if routeKeepsRunningWhileSpotShown { return false }
        return showsRoutePanelActive ? routePeekDisabled : (spoofState == .verifying || spotStopPending || spotSwitchPending)
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
        case .preparing where route.start == nil:
            return "设为起点"
        case .preparing where route.end == nil:
            return "终点"
        default:
            return "开始"
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
        if route.waitingForActivation || route.isRouting { return true }
        if route.phase == .preparing { return false }
        return !route.canPlay
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
        case .preparing where route.end == nil:
            route.setEnd(currentSelectionPair)
        default:
            playRoute()
        }
    }

    /// 在“路线”切换项上提示后台路线状态。
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
        RoutePlaybackPanel(
            route: route, clock: route.clock, currentPair: currentSelectionPair,
            onExit: requestExitRoute, onSave: promptSaveRoute, onOpenSaved: openSavedRoutes,
            onRestart: { playRoute(fromStart: true) }, embedded: true
        )
    }

    func playRoute(fromStart: Bool = false) {
        guard session.resumeWrites() else { return }
        stopPhysicalWalkForRoutePlayback()
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
        guard route.start != nil else { return }
        route.requestPlay()
        guard route.waitingForActivation else { return }
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
        guard route.start != nil else { return }
        guard route.canPlay else {
            route.requestPlay()
            return
        }
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
        guard let start = route.start else { return }
        route.requestPlay()
        guard route.waitingForActivation else { return }
        if spoofState == .active {
            route.beginActivation()
            return
        }
        let startFavorite = FavoriteLocation(
            name: "路线",
            coordinatePair: start,
            accuracy: LocationAccuracyStore.shared.meters
        )
        route.beginActivation {
            beginLocationOperation(target: startFavorite, isRouteActivation: true)
            await session.waitForOperation()
            return session.state == .active && !session.writesSuspended
        }
    }

    func beginRouteLocation() -> Bool {
        guard RouteLocationLaunch.prepare(route, readiness: routeLocation.readiness) == nil else {
            showRouteLocationSetup = true
            return false
        }
        return true
    }

    /// 换路线或取消开启等待时，不再清掉已经写下的模拟。退出和走完由定点接管。
    func settleRouteSimulation(after pendingWrite: Task<Void, Never>?, from previous: RoutePhase) {
        guard RouteLocationStop.shouldClearSimulation(
            from: previous,
            to: route.phase,
            activationWritePending: pendingWrite != nil
        ) else { return }
        Task { @MainActor in
            await pendingWrite?.value
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
            break
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
    var physicalWalkText: String? = nil

    var body: some View {
        if let text = caption {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var caption: String? {
        if showsRoute { return routeCaption }
        if let physicalWalkText { return physicalWalkText }
        return backgroundCaption
    }

    private var routeCaption: String? {
        switch route.phase {
        case .playing, .paused:
            _ = clock.progress
            let remaining = RoutePlayback.formattedRemaining(
                meters: route.remainingMeters,
                speedMetersPerSecond: route.speedMetersPerSecond
            )
            let speed = RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour)
            return "\(speed) · \(remaining)"
        case .finished:
            return "已走完"
        case .preparing:
            if route.isRouting { return "正在规划路线" }
            if route.start == nil || route.end == nil { return "先设起点和终点" }
            if route.canPlay { return RoutePlayback.formattedDistance(route.distanceMeters) }
            return "起点和终点太近"
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
        syncPhysicalWalk()
    }
}
