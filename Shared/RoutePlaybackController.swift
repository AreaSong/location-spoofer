import Foundation
import CoreLocation

enum RoutePhase: Equatable {
    case inactive
    case preparing
    case playing
    case paused
    case finished
}

@MainActor
final class RoutePlaybackController: ObservableObject {
    static let maxViaCount = 5

    let clock = RoutePlaybackClock()

    @Published private(set) var phase: RoutePhase = .inactive {
        didSet { publishMarker() }
    }
    @Published var travelMode: RouteTravelMode
    @Published var speedKilometersPerHour: Double
    @Published var offsetMeters: Double
    @Published var repeatMode: RouteRepeatMode
    @Published private(set) var start: CoordinatePair?
    @Published private(set) var end: CoordinatePair?
    @Published private(set) var vias: [CoordinatePair] = []
    @Published private(set) var path: RoutePath?
    @Published private(set) var pathFallback: RoutePathFallback?
    private(set) var progress: Double = 0 {
        didSet { clock.setProgress(progress) }
    }
    private(set) var current: CoordinatePair? {
        didSet {
            clock.setCurrent(current)
            publishMarker()
        }
    }
    @Published private(set) var waitingForActivation = false
    @Published private(set) var isRouting = false
    @Published private(set) var pathRevision: UInt64 = 0
    @Published private(set) var editingSavedRoute: SavedRoute?
    var statusMessage = "" {
        didSet { clock.setStatusMessage(statusMessage) }
    }

    var applyCoordinate: ((CoordinatePair) async -> Bool)?
    var tickIntervalNanoseconds: UInt64 = 1_000_000_000
    /// 开发者定位推送每次采样都写，不再等 8 米或 5 秒。
    var ignoresWriteGate = false
    var pushFailureMessage = "系统定位推送失败，已暂停。"
    @Published private(set) var interruption: RouteInterruption = .playing
    let sessionStore: RouteSessionStore

    private(set) var headingForward = true
    private var elapsed: TimeInterval = 0
    private var playbackOrigin = Date()
    private var playbackTask: Task<Void, Never>?
    /// 开启等待期间写入起点。退出时要取消，否则播放任务还没创建，旧任务仍会写坐标。
    private var activationTask: Task<Void, Never>?
    /// 起点写入已经发出。取消只能挡住还没开始的写入，已经发出的要等它结束再清定位。
    private var activationDidWrite = false
    /// 停止或重新开始播放时加一。挂起的写入返回后用它丢掉过期结果。
    private var playbackGeneration: UInt64 = 0
    private var pathGeneration: UInt64 = 0
    private var writeGate = RouteWriteGate()
    private let preferenceStore: RoutePlaybackPreferenceStore
    private var pendingRecovery: RouteSession?
    private var recoveredProgress: Double?
    private var lastSessionProgress = -1.0
    private var lastSessionWrite = Date.distantPast

    init(
        preferenceStore: RoutePlaybackPreferenceStore = RoutePlaybackPreferenceStore(),
        sessionStore: RouteSessionStore = RouteSessionStore()
    ) {
        self.preferenceStore = preferenceStore
        self.sessionStore = sessionStore
        let prefs = preferenceStore.load()
        travelMode = prefs.travelMode
        speedKilometersPerHour = prefs.speedKilometersPerHour
        offsetMeters = prefs.offsetMeters
        repeatMode = prefs.repeatMode
    }

    var speedMetersPerSecond: Double {
        max(speedKilometersPerHour / 3.6, 0.1)
    }

    var canPlay: Bool {
        (path?.totalMeters ?? distanceMeters) >= RoutePlayback.minimumDistanceMeters
    }

    var canReverse: Bool {
        start != nil && end != nil && !isRouting && phase != .playing && phase != .paused
    }

    var canEditVias: Bool {
        start != nil && phase == .preparing
    }

    var canOverwriteSavedRoute: Bool { editingSavedRoute != nil }

    var pathNotice: String? { pathFallback?.notice }

    var locksPathEdits: Bool {
        phase == .playing || phase == .paused
    }

    var anchors: [CoordinatePair] {
        guard let start, let end else { return [] }
        return [start] + vias + [end]
    }

    var distanceMeters: Double {
        if let path, path.totalMeters > 0 { return path.totalMeters }
        return RoutePlayback.distanceMeters(along: anchors)
    }

    var remainingMeters: Double {
        let leg = max(0, (1 - progress) * distanceMeters)
        if repeatMode == .roundTrip, headingForward {
            return leg + distanceMeters
        }
        return leg
    }

    var overlayCoordinates: [CLLocationCoordinate2D] {
        let system = CoordinateConverter.currentMapCoordinateSystem
        if let path, path.points.count >= 2 {
            return path.points.map { $0.coordinate(for: system) }
        }
        return previewAnchors.map { $0.coordinate(for: system) }
    }

    private var previewAnchors: [CoordinatePair] {
        guard let start else { return [] }
        if let end { return [start] + vias + [end] }
        if vias.isEmpty { return [] }
        return [start] + vias
    }

    var overlayPins: [RouteMapPin] {
        let system = CoordinateConverter.currentMapCoordinateSystem
        var pins: [RouteMapPin] = []
        if let start {
            pins.append(RouteMapPin(coordinate: start.coordinate(for: system), role: .start))
        }
        for (index, via) in vias.enumerated() {
            pins.append(RouteMapPin(coordinate: via.coordinate(for: system), role: .via(index + 1)))
        }
        if let end {
            pins.append(RouteMapPin(coordinate: end.coordinate(for: system), role: .end))
        }
        return pins
    }

    func enter(start pair: CoordinatePair? = nil) {
        stopPlaybackTask()
        endRouteKeepAlive()
        stopActivationTask()
        pathGeneration &+= 1
        headingForward = true
        start = pair
        end = nil
        vias = []
        path = nil
        current = pair
        progress = 0
        elapsed = 0
        waitingForActivation = false
        isRouting = false
        editingSavedRoute = nil
        pathFallback = nil
        refreshReadyMessage()
        phase = .preparing
    }

    @discardableResult
    func load(_ saved: SavedRoute) -> Task<Void, Never>? {
        stopPlaybackTask()
        endRouteKeepAlive()
        let pendingWrite = takePendingActivationWrite()
        pathGeneration &+= 1
        headingForward = true
        waitingForActivation = false
        pendingRecovery = nil
        recoveredProgress = nil
        start = saved.start
        end = saved.end
        vias = saved.viaPoints
        travelMode = saved.travelMode
        speedKilometersPerHour = min(40, max(1, saved.speedKilometersPerHour))
        offsetMeters = min(80, max(0, saved.offsetMeters))
        repeatMode = saved.repeatMode
        progress = 0
        elapsed = 0
        phase = .preparing
        editingSavedRoute = saved
        pathFallback = saved.straightFallback
        persistPreferences()
        if let points = saved.pathPoints, points.count >= 2 {
            path = RoutePath.make(points)
            current = path?.points.first ?? saved.start
            isRouting = false
            refreshReadyMessage()
            bumpPathRevision()
            return pendingWrite
        }
        path = nil
        current = saved.start
        isRouting = false
        Task { await rebuildPath() }
        return pendingWrite
    }

    func makeSavedRoute(name: String, overwrite: Bool = false) -> SavedRoute? {
        guard let start, let end, canPlay, !isRouting else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = path?.points
        let replacing = overwrite ? editingSavedRoute : nil
        return SavedRoute(
            id: replacing?.id ?? UUID(),
            name: trimmed.isEmpty ? (replacing?.name ?? RoutePlayback.formattedDistance(distanceMeters)) : trimmed,
            start: start,
            end: end,
            travelMode: travelMode,
            speedKilometersPerHour: speedKilometersPerHour,
            offsetMeters: offsetMeters,
            repeatMode: repeatMode,
            viaPoints: vias,
            pathPoints: (points?.count ?? 0) >= 2 ? points : nil,
            straightFallback: pathFallback,
            createdAt: replacing?.createdAt ?? Date()
        )
    }

    func noteSaved(_ saved: SavedRoute) {
        editingSavedRoute = saved
    }

    func setStart(_ pair: CoordinatePair) {
        guard !locksPathEdits else { return }
        start = pair
        current = pair
        Task { await rebuildPath() }
    }

    func setEnd(_ pair: CoordinatePair) {
        guard !locksPathEdits else { return }
        end = pair
        Task { await rebuildPath() }
    }

    func addVia(_ pair: CoordinatePair) {
        guard !locksPathEdits, canEditVias, let start else { return }
        if let index = indexOfVia(near: pair, within: 20) {
            vias[index] = pair
            statusMessage = "已更新途经 \(index + 1)。"
            Task { await rebuildPath() }
            return
        }
        guard vias.count < Self.maxViaCount else {
            statusMessage = "途经点已满，点橙色数字删除后再加。"
            return
        }
        let previous = vias.last ?? start
        guard RoutePlayback.distanceMeters(from: previous, to: pair) >= RoutePlayback.minimumDistanceMeters else {
            statusMessage = "途经点和上一个点太近，请再拉开一些。"
            return
        }
        vias.append(pair)
        Task { await rebuildPath() }
    }

    func removeVia(at index: Int) {
        guard !locksPathEdits, phase == .preparing, vias.indices.contains(index) else { return }
        vias.remove(at: index)
        statusMessage = vias.isEmpty ? "已删除途经点。" : "已删除途经 \(index + 1)。"
        Task { await rebuildPath() }
    }

    func removeLastVia() {
        guard !vias.isEmpty else { return }
        removeVia(at: vias.count - 1)
    }

    private func indexOfVia(near pair: CoordinatePair, within meters: Double) -> Int? {
        vias.firstIndex {
            RoutePlayback.distanceMeters(from: $0, to: pair) <= meters
        }
    }

    func reverseDirection() {
        guard !locksPathEdits, canReverse, let start, let end else { return }
        headingForward = true
        elapsed = 0
        progress = 0
        self.start = end
        self.end = start
        vias.reverse()
        if let path, path.points.count >= 2 {
            self.path = path.reversed()
            current = self.path?.points.first ?? self.start
            refreshReadyMessage()
            bumpPathRevision()
            return
        }
        current = self.start
        Task { await rebuildPath() }
    }

    func requestPlay() {
        guard canPlay else {
            statusMessage = "起点和终点太近，请再拉开一些。"
            return
        }
        headingForward = true
        elapsed = 0
        progress = 0
        current = path?.points.first ?? start
        waitingForActivation = true
        statusMessage = "正在开启虚拟定位…"
    }

    /// `requestPlay()` 之后调用。任务挂在控制器上，退出、取消等待和换路线都会取消它。
    func beginActivation() {
        stopActivationTask()
        guard waitingForActivation, let pair = current ?? start else { return }
        activationTask = Task { [weak self] in
            await self?.runActivation(pair)
        }
    }

    func noteActivated() {
        guard waitingForActivation else { return }
        waitingForActivation = false
        startLoop()
    }

    @discardableResult
    func cancelWaiting() -> Task<Void, Never>? {
        let pendingWrite = takePendingActivationWrite()
        waitingForActivation = false
        if phase == .playing { return pendingWrite }
        if phase != .inactive {
            phase = .preparing
            statusMessage = "未能开启虚拟定位，路线仍可修改。"
        }
        return pendingWrite
    }

    func pause() {
        guard phase == .playing else { return }
        stopPlaybackTask()
        endRouteKeepAlive()
        phase = .paused
        interruption = .userPaused
        statusMessage = "已暂停。"
        captureSession(force: true)
    }

    func resume() {
        guard phase == .paused, canPlay else { return }
        interruption = .playing
        startLoop()
    }

    func resetProgressForRestart() {
        stopPlaybackTask()
        endRouteKeepAlive()
        headingForward = true
        elapsed = 0
        progress = 0
        interruption = .playing
        waitingForActivation = false
        current = path?.points.first ?? start
        phase = .preparing
        refreshReadyMessage()
    }

    func applyRecovery(_ session: RouteSession) {
        _ = load(session.savedRoute())
        if path == nil {
            path = RoutePath.make([session.start] + session.viaPoints + [session.end])
        }
        pendingRecovery = session
        applyPendingRecovery()
    }

    /// 返回已经发出、但还没结束的起点写入。调用方应等它完成后再清系统定位。
    @discardableResult
    func exit() -> Task<Void, Never>? {
        stopPlaybackTask()
        endRouteKeepAlive()
        let pendingWrite = takePendingActivationWrite()
        pathGeneration &+= 1
        headingForward = true
        waitingForActivation = false
        isRouting = false
        start = nil
        end = nil
        vias = []
        path = nil
        current = nil
        progress = 0
        elapsed = 0
        statusMessage = ""
        editingSavedRoute = nil
        pathFallback = nil
        ignoresWriteGate = false
        interruption = .playing
        pendingRecovery = nil
        recoveredProgress = nil
        phase = .inactive
        clearSession()
        return pendingWrite
    }

    func refreshReadyMessage() {
        guard start != nil else {
            statusMessage = "点「起点」，路上可加「途经」，再点「终点」。开始后会直接出现在起点，不会从你现在的定位走过来。"
            return
        }
        guard end != nil else {
            if vias.isEmpty {
                statusMessage = "再把图钉移到终点，点「终点」。路上要转弯就先点「途经」。"
            } else {
                statusMessage = "已加 \(vias.count) 个途经点。再点「终点」，或继续加途经。"
            }
            return
        }
        if isRouting {
            statusMessage = "正在规划沿路路线…"
            return
        }
        let meters = distanceMeters
        guard meters >= RoutePlayback.minimumDistanceMeters else {
            statusMessage = "起点和终点太近，请再拉开一些。"
            return
        }
        statusMessage = readyStatusMessage(meters: meters)
    }

    func setSpeedKilometersPerHour(_ value: Double) {
        let next = min(40, max(1, value))
        if phase == .playing || phase == .paused {
            rebaseElapsed(toSpeedKilometersPerHour: next)
        }
        speedKilometersPerHour = next
        persistPreferences()
        if phase == .playing || phase == .paused {
            statusMessage = playbackStatusMessage()
        } else {
            refreshReadyMessage()
        }
    }

    private func rebaseElapsed(toSpeedKilometersPerHour kmh: Double) {
        guard let path, path.totalMeters > 0 else { return }
        elapsed = RoutePlayback.elapsed(
            progress: progress,
            totalMeters: path.totalMeters,
            speedMetersPerSecond: max(kmh / 3.6, 0.1)
        )
        playbackOrigin = Date().addingTimeInterval(-elapsed)
    }

    func setOffsetMeters(_ value: Double) {
        offsetMeters = min(80, max(0, value))
        persistPreferences()
    }

    func applyTravelMode(_ mode: RouteTravelMode) {
        guard !locksPathEdits else { return }
        travelMode = mode
        let next = mode.kilometersPerHour
        if isPlaybackInProgress {
            rebaseElapsed(toSpeedKilometersPerHour: next)
        }
        speedKilometersPerHour = next
        persistPreferences()
        if isPlaybackInProgress {
            statusMessage = phase == .paused ? "已暂停。" : playbackStatusMessage()
        }
        Task { await rebuildPath() }
    }

    func applyRepeatMode(_ mode: RouteRepeatMode) {
        repeatMode = mode
        persistPreferences()
        if phase == .playing || phase == .paused { return }
        refreshReadyMessage()
    }

    func rebuildPath() async {
        let points = anchors
        guard points.count >= 2 else {
            path = nil
            pathFallback = nil
            refreshReadyMessage()
            return
        }
        let keepCurrentPath = isPlaybackInProgress && path != nil
        if !keepCurrentPath {
            path = RoutePath.make(points)
        }
        pathGeneration &+= 1
        let generation = pathGeneration
        isRouting = true
        refreshReadyMessage()
        restorePlaybackStatusIfNeeded()
        let routed = await RouteDirections.waypoints(along: points, mode: travelMode)
        guard generation == pathGeneration else { return }
        path = RoutePath.make(routed.points)
        pathFallback = routed.fallback
        isRouting = false
        if isPlaybackInProgress {
            rebaseElapsed(toSpeedKilometersPerHour: speedKilometersPerHour)
            snapCurrentToProgress()
        }
        refreshReadyMessage()
        restorePlaybackStatusIfNeeded()
        bumpPathRevision()
        applyPendingRecovery()
        reapplyRecoveredProgress()
    }

    private var isPlaybackInProgress: Bool {
        phase == .playing || phase == .paused
    }

    /// 路径换成另一条以后，标记停在同一进度上，避免还显示旧路线上的点。
    private func snapCurrentToProgress() {
        guard let path, path.totalMeters > 0 else { return }
        let active = headingForward ? path : path.reversed()
        current = RoutePlayback.interpolate(path: active, progress: progress)
    }

    private func restorePlaybackStatusIfNeeded() {
        guard isPlaybackInProgress else { return }
        statusMessage = phase == .paused ? "已暂停。" : playbackStatusMessage()
    }

    /// Returns true when playback should stop after this leg.
    func handleFinishedLeg() -> Bool {
        switch repeatMode {
        case .once:
            return true
        case .roundTrip:
            if headingForward {
                headingForward = false
                return false
            }
            return true
        case .loop:
            headingForward.toggle()
            return false
        }
    }

    private func startLoop() {
        stopPlaybackTask()
        let generation = playbackGeneration
        writeGate.reset()
        beginRouteKeepAlive()
        interruption = .playing
        recoveredProgress = nil
        phase = .playing
        statusMessage = playbackStatusMessage()
        playbackOrigin = Date().addingTimeInterval(-elapsed)
        captureSession(force: true)
        playbackTask = Task { [weak self] in
            await self?.runLoop(generation: generation)
        }
    }

    private func runLoop(generation: UInt64) async {
        while isPlaybackCurrent(generation), phase == .playing {
            guard let basePath = path, basePath.points.count >= 2 else { break }
            let activePath = headingForward ? basePath : basePath.reversed()
            elapsed = Date().timeIntervalSince(playbackOrigin)
            let tick = RoutePlayback.tick(
                path: activePath,
                speedMetersPerSecond: speedMetersPerSecond,
                elapsed: elapsed
            )
            current = tick.coordinatePair
            progress = tick.progress
            let now = Date()
            let forceWrite = tick.isFinished
            let due = ignoresWriteGate || writeGate.shouldWrite(tick.coordinatePair, at: now, force: forceWrite)
            if due {
                let applied = await applyCoordinate?(tick.coordinatePair) ?? false
                // 写入挂起期间，这一轮可能已取消，或已被新播放替换。
                guard isPlaybackCurrent(generation) else { return }
                if !applied {
                    notePushFailure()
                    return
                }
                writeGate.markWritten(tick.coordinatePair, at: now)
            }
            guard isPlaybackCurrent(generation) else { return }
            if tick.isFinished {
                if handleFinishedLeg() {
                    phase = .finished
                    statusMessage = finishedStatusMessage()
                    endRouteKeepAlive()
                    clearSession()
                    return
                }
                playbackOrigin = Date()
                elapsed = 0
                progress = 0
                statusMessage = playbackStatusMessage()
                continue
            }
            statusMessage = playbackStatusMessage()
            captureSession(force: false)
            try? await Task.sleep(nanoseconds: tickIntervalNanoseconds)
        }
        if isPlaybackCurrent(generation), phase == .playing {
            endRouteKeepAlive()
        }
    }

    private func isPlaybackCurrent(_ generation: UInt64) -> Bool {
        generation == playbackGeneration && !Task.isCancelled
    }

    private func notePushFailure() {
        if phase == .playing {
            pause()
        }
        interruption = .pushFailed
        statusMessage = pushFailureMessage
        captureSession(force: true)
    }

    private func captureSession(force: Bool) {
        guard let start, let end else { return }
        let now = Date()
        if !force,
           abs(progress - lastSessionProgress) < 0.01,
           now.timeIntervalSince(lastSessionWrite) < 5 {
            return
        }
        sessionStore.save(RouteSession(
            routeID: editingSavedRoute?.id,
            name: editingSavedRoute?.name ?? travelMode.displayName,
            start: start,
            end: end,
            viaPoints: vias,
            travelMode: travelMode,
            speedKilometersPerHour: speedKilometersPerHour,
            offsetMeters: offsetMeters,
            repeatMode: repeatMode,
            straightFallback: pathFallback,
            progress: progress,
            elapsed: elapsed,
            headingForward: headingForward,
            interruption: interruption,
            updatedAt: now
        ))
        lastSessionProgress = progress
        lastSessionWrite = now
    }

    private func clearSession() {
        sessionStore.clear()
        lastSessionProgress = -1
        lastSessionWrite = .distantPast
    }

    private func applyPendingRecovery() {
        guard let session = pendingRecovery, path != nil else { return }
        progress = min(1, max(0, session.progress))
        elapsed = session.elapsed
        headingForward = session.headingForward
        interruption = session.interruption == .playing ? .userPaused : session.interruption
        recoveredProgress = progress
        snapCurrentToProgress()
        if interruption == .activationFailed {
            phase = .preparing
            statusMessage = pushFailureMessage
        } else if interruption == .pushFailed {
            phase = .paused
            statusMessage = pushFailureMessage
        } else {
            phase = .paused
            statusMessage = RouteActivitySync.userPauseMessage
        }
        pendingRecovery = nil
        captureSession(force: true)
    }

    private func reapplyRecoveredProgress() {
        guard let recoveredProgress, path != nil else { return }
        guard phase == .paused || phase == .preparing else { return }
        progress = recoveredProgress
        elapsed = RoutePlayback.elapsed(
            progress: progress,
            totalMeters: path?.totalMeters ?? 0,
            speedMetersPerSecond: speedMetersPerSecond
        )
        snapCurrentToProgress()
    }

    func bumpPathRevision() {
        pathRevision &+= 1
    }

    func persistPreferences() {
        preferenceStore.save(
            RoutePlaybackPreferences(
                travelMode: travelMode,
                speedKilometersPerHour: speedKilometersPerHour,
                offsetMeters: offsetMeters,
                repeatMode: repeatMode
            )
        )
    }

    private func runActivation(_ pair: CoordinatePair) async {
        guard !Task.isCancelled, waitingForActivation else { return }
        activationDidWrite = true
        let applied = await applyCoordinate?(pair) ?? false
        guard !Task.isCancelled, waitingForActivation else { return }
        activationDidWrite = false
        if applied {
            noteActivated()
        } else {
            cancelWaiting()
            interruption = .activationFailed
            statusMessage = pushFailureMessage
            captureSession(force: true)
        }
    }

    /// 写入还没发出时直接丢掉任务；已经发出则把任务交还调用方，等写入落地后再清理。
    private func takePendingActivationWrite() -> Task<Void, Never>? {
        let task = activationTask
        let wrote = activationDidWrite
        activationTask?.cancel()
        activationTask = nil
        activationDidWrite = false
        return wrote ? task : nil
    }

    private func stopActivationTask() {
        activationTask?.cancel()
        activationTask = nil
        activationDidWrite = false
    }

    private func stopPlaybackTask() {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func beginRouteKeepAlive() {
        BackgroundKeepAlive.shared.retain(.routePlayback)
    }

    private func endRouteKeepAlive() {
        BackgroundKeepAlive.shared.release(.routePlayback)
    }
}
