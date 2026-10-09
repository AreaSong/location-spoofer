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
    static let maxViaCount = 10

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

    var onLocationKept: (() -> Void)?
    var onPlaybackIntent: (() -> Bool)?
    var applyCoordinate: ((CoordinatePair) async -> Bool)?
    var now: () -> Date = { Date() }
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
    /// 起点激活属于路线生命周期；退出时撤销未开始部分，已开始部分交给收尾屏障。
    private var activationTask: Task<Void, Never>?
    /// 已进入激活协调边界，必须等结果返回；保留位置的退出不清除模拟。
    private var activationDidWrite = false
    private var playbackDidWrite = false
    /// 至多一个已开始的生产者留在这里收尾；新生产者必须先等它返回。
    private var pendingWriteTask: Task<Void, Never>?
    private var producerStartTask: Task<Void, Never>?
    private var pendingProducerStart: (() -> Void)?
    private(set) var producerStartID: UUID?
    private var handoffTask: Task<Void, Never>?
    private var pendingHandoff: (generation: UInt64, drain: Task<Void, Never>?, kept: (() -> Void)?)?
    private var handoffGeneration: UInt64 = 0
    private var handoffRequested = false
    private var locationWasRequested = false
    /// 停止或重新开始播放时加一。挂起的写入返回后用它丢掉过期结果。
    private var playbackGeneration: UInt64 = 0
    private(set) var submissionGeneration: UInt64 = 0
    private var pathGeneration: UInt64 = 0
    private var writeGate = RouteWriteGate()
    private let preferenceStore: RoutePlaybackPreferenceStore
    private var pendingRecovery: RouteSession?
    private var recoveredProgress: Double?
    private var lastSessionProgress = -1.0
    private var lastSessionWrite = Date.distantPast
    /// 行走中加途经后，按「当前位置 → 新点 → 未走途经 → 终点」规划剩余路。
    private var playbackAnchorsOverride: [CoordinatePair]?
    private var rebasesPlaybackToPathStart = false

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
        distanceMeters >= RoutePlayback.minimumDistanceMeters
    }

    var canReverse: Bool {
        start != nil && end != nil && !isRouting && phase != .playing && phase != .paused
    }

    var canEditVias: Bool {
        start != nil && (phase == .preparing || isPlaybackInProgress)
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
        max(path?.totalMeters ?? 0, RoutePlayback.distanceMeters(along: anchors))
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
        invalidateHandoff()
        locationWasRequested = false
        stopPlaybackTask()
        endRouteKeepAlive()
        stopActivationTask()
        pathGeneration &+= 1
        headingForward = true
        start = pair
        end = nil
        vias = []
        clearPlaybackDetour()
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
        invalidateHandoff()
        locationWasRequested = false
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
        clearPlaybackDetour()
        travelMode = saved.travelMode
        speedKilometersPerHour = saved.travelMode.clampedSpeed(saved.speedKilometersPerHour)
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
        guard canEditVias, start != nil else { return }
        if isPlaybackInProgress {
            insertUpcomingVia(pair)
            return
        }
        guard !locksPathEdits else { return }
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
        guard let previous,
              RoutePlayback.distanceMeters(from: previous, to: pair) >= RoutePlayback.minimumDistanceMeters else {
            statusMessage = "途经点和上一个点太近，请再拉开一些。"
            return
        }
        vias.append(pair)
        Task { await rebuildPath() }
    }

    private func insertUpcomingVia(_ pair: CoordinatePair) {
        guard let current, end != nil else { return }
        if let index = indexOfVia(near: pair, within: 20) {
            vias[index] = pair
            statusMessage = "已更新途经 \(index + 1)。"
            let split = splitViasByProgress()
            continuePlaybackThroughRemaining(from: current, upcomingPrefix: split.upcoming)
            return
        }
        guard vias.count < Self.maxViaCount else {
            statusMessage = "途经点已满，点橙色数字删除后再加。"
            return
        }
        guard RoutePlayback.distanceMeters(from: current, to: pair) >= RoutePlayback.minimumDistanceMeters else {
            statusMessage = "途经点和当前位置太近，请再拉开一些。"
            return
        }
        let split = splitViasByProgress()
        // 后加的点排在还没走到的途经点后面、终点前面，避免新点变成 1 号并打乱原顺序。
        vias = split.visited + split.upcoming + [pair]
        statusMessage = "正在接入新的途经点…"
        continuePlaybackThroughRemaining(from: current, upcomingPrefix: split.upcoming + [pair])
    }

    private func splitViasByProgress() -> (visited: [CoordinatePair], upcoming: [CoordinatePair]) {
        guard let path, path.totalMeters > 0 else { return ([], vias) }
        var visited: [CoordinatePair] = []
        var upcoming: [CoordinatePair] = []
        for via in vias {
            if RoutePlayback.nearestProgress(of: via, on: path) <= progress + 0.02 {
                visited.append(via)
            } else {
                upcoming.append(via)
            }
        }
        return (visited, upcoming)
    }

    private func continuePlaybackThroughRemaining(from current: CoordinatePair, upcomingPrefix: [CoordinatePair]) {
        guard let end else { return }
        playbackAnchorsOverride = [current] + upcomingPrefix + [end]
        rebasesPlaybackToPathStart = true
        Task { await rebuildPath() }
    }

    private func clearPlaybackDetour() {
        playbackAnchorsOverride = nil
        rebasesPlaybackToPathStart = false
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
        invalidateHandoff()
        guard onPlaybackIntent?() ?? true else { return }
        headingForward = true
        elapsed = 0
        progress = 0
        clearPlaybackDetour()
        current = path?.points.first ?? start
        waitingForActivation = true
        statusMessage = "正在开启虚拟定位…"
    }

    /// `requestPlay()` 之后调用；控制器持有任务，换路线前先排空已开始的激活。
    func beginActivation(using operation: (() async -> Bool)? = nil) {
        stopActivationTask()
        guard waitingForActivation, let pair = current ?? start else { return }
        scheduleProducerStart { [weak self] in
            self?.activationTask = Task { [weak self] in
                await self?.runActivation(pair, operation: operation)
            }
        }
    }

    func noteActivated() {
        guard waitingForActivation else { return }
        waitingForActivation = false
        locationWasRequested = true
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

    /// 定位通道被挡住时停住播放，但不要记成用户暂停，否则灵动岛会给出「继续」。
    func pauseBecauseLocationBlocked() {
        guard phase == .playing else { return }
        stopPlaybackTask()
        endRouteKeepAlive()
        phase = .paused
        interruption = .pushFailed
        statusMessage = RouteActivitySync.locationBlockedMessage
        captureSession(force: true)
    }

    /// 用户已经暂停时，定位被挡住不能再显示「继续」。
    func markPausedLocationBlocked() {
        guard phase == .paused else { return }
        interruption = .pushFailed
        statusMessage = RouteActivitySync.locationBlockedMessage
        captureSession(force: true)
    }

    func markActivationFailed(_ message: String) {
        guard phase == .preparing || phase == .paused else { return }
        phase = .preparing
        interruption = .activationFailed
        statusMessage = message
        captureSession(force: true)
    }

    /// 停下播放，保留已写下的虚拟定位。回到可编辑，不走退出清理。
    func stopPlaybackKeepingLocation() {
        guard phase == .playing || phase == .paused else { return }
        stopPlaybackTask()
        endRouteKeepAlive()
        waitingForActivation = false
        phase = .preparing
        interruption = .playing
        statusMessage = "路线已停止，定位仍保持。"
        captureSession(force: true)
        requestLocationHandoff()
    }

    func resume() {
        guard phase == .paused, canPlay else { return }
        invalidateHandoff()
        guard onPlaybackIntent?() ?? true else { return }
        interruption = .playing
        startLoop()
    }

    func resetProgressForRestart() {
        invalidateHandoff()
        stopPlaybackTask()
        endRouteKeepAlive()
        headingForward = true
        elapsed = 0
        progress = 0
        interruption = .playing
        waitingForActivation = false
        clearPlaybackDetour()
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

    /// 停止生产，返回激活或播放写入的收尾任务；定点接管由同一个生命周期完成。
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
        clearPlaybackDetour()
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
        requestLocationHandoff()
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
        let next = travelMode.clampedSpeed(value)
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
        playbackOrigin = now().addingTimeInterval(-elapsed)
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
        let points = playbackAnchorsOverride ?? anchors
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
        if playbackAnchorsOverride != nil || rebasesPlaybackToPathStart {
            progress = 0
            elapsed = 0
            playbackOrigin = now()
            current = path?.points.first ?? current
            rebasesPlaybackToPathStart = false
        } else if isPlaybackInProgress {
            rebaseElapsed(toSpeedKilometersPerHour: speedKilometersPerHour)
            snapCurrentToProgress()
        }
        refreshReadyMessage()
        restorePlaybackStatusIfNeeded()
        bumpPathRevision()
        applyPendingRecovery()
        if playbackAnchorsOverride == nil {
            reapplyRecoveredProgress()
        }
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
        playbackOrigin = now().addingTimeInterval(-elapsed)
        captureSession(force: true)
        scheduleProducerStart { [weak self] in
            self?.playbackTask = Task { [weak self] in
                await self?.runLoop(generation: generation)
            }
        }
    }

    private func runLoop(generation: UInt64) async {
        var lastTickTime = now()
        while isPlaybackCurrent(generation), phase == .playing {
            guard let basePath = path, basePath.points.count >= 2 else { break }
            let activePath = headingForward ? basePath : basePath.reversed()
            let currentNow = now()
            let tick: RouteTick
            if SmoothCruiseStore.shared.isCorneringDecelerationEnabled {
                let dt = min(max(currentNow.timeIntervalSince(lastTickTime), 0.05), 3.0)
                let adjustedSpeed = RoutePlayback.adjustedRealisticSpeed(
                    baseSpeed: speedMetersPerSecond,
                    path: activePath,
                    progress: progress,
                    elapsed: elapsed
                )
                let deltaMeters = adjustedSpeed * dt
                let deltaProgress = deltaMeters / max(activePath.totalMeters, 0.1)
                let newProgress = min(1.0, max(0.0, progress + deltaProgress))
                let newCoord = RoutePlayback.interpolate(path: activePath, progress: newProgress)
                tick = RouteTick(
                    coordinatePair: newCoord,
                    progress: newProgress,
                    remainingMeters: activePath.totalMeters * (1 - newProgress),
                    isFinished: newProgress >= 1
                )
                elapsed = RoutePlayback.elapsed(
                    progress: newProgress,
                    totalMeters: activePath.totalMeters,
                    speedMetersPerSecond: speedMetersPerSecond
                )
                playbackOrigin = currentNow.addingTimeInterval(-elapsed)
            } else {
                elapsed = currentNow.timeIntervalSince(playbackOrigin)
                tick = RoutePlayback.tick(
                    path: activePath,
                    speedMetersPerSecond: speedMetersPerSecond,
                    elapsed: elapsed
                )
            }
            lastTickTime = currentNow
            current = tick.coordinatePair
            progress = tick.progress
            let now = currentNow
            let forceWrite = tick.isFinished
            let due = ignoresWriteGate || writeGate.shouldWrite(tick.coordinatePair, at: now, force: forceWrite)
            if due {
                playbackDidWrite = true
                locationWasRequested = true
                let applied = await applyCoordinate?(tick.coordinatePair) ?? false
                // 写入挂起期间，这一轮可能已取消，或已被新播放替换。
                guard isPlaybackCurrent(generation) else { return }
                playbackDidWrite = false
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
                    requestLocationHandoff()
                    return
                }
                playbackOrigin = self.now()
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
        locationWasRequested = true
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

    private func runActivation(_ pair: CoordinatePair, operation: (() async -> Bool)?) async {
        guard !Task.isCancelled, waitingForActivation else { return }
        let generation = handoffGeneration
        activationDidWrite = true
        locationWasRequested = true
        let applied: Bool
        if let operation { applied = await operation() }
        else { applied = await applyCoordinate?(pair) ?? false }
        guard !Task.isCancelled, waitingForActivation, generation == handoffGeneration else { return }
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

    /// 不取消已开始的调用：取消会让下层丢掉成功收据，却无法撤销设备副作用。
    private func takePendingActivationWrite() -> Task<Void, Never>? {
        submissionGeneration &+= 1
        pendingProducerStart = nil
        if activationDidWrite {
            pendingWriteTask = activationTask
        } else {
            activationTask?.cancel()
        }
        activationTask = nil
        activationDidWrite = false
        return pendingWriteTask
    }

    private func stopActivationTask() {
        _ = takePendingActivationWrite()
    }

    private func stopPlaybackTask() {
        submissionGeneration &+= 1
        pendingProducerStart = nil
        playbackGeneration &+= 1
        if playbackDidWrite {
            pendingWriteTask = playbackTask
        } else {
            playbackTask?.cancel()
        }
        playbackTask = nil
        playbackDidWrite = false
    }

    /// 快速暂停/重启只替换一个待启动意图，不为每次点击创建等待设备的任务。
    private func scheduleProducerStart(_ start: @escaping () -> Void) {
        guard let pending = pendingWriteTask else { start(); return }
        pendingProducerStart = start
        guard producerStartTask == nil else { return }
        producerStartID = UUID()
        producerStartTask = Task { [weak self] in
            await pending.value
            guard let self else { return }
            self.pendingWriteTask = nil
            self.producerStartTask = nil
            self.producerStartID = nil
            let next = self.pendingProducerStart
            self.pendingProducerStart = nil
            next?()
        }
    }

    private func invalidateHandoff() {
        handoffGeneration &+= 1
        pendingHandoff = nil
        handoffRequested = false
    }

    private func requestLocationHandoff() {
        guard locationWasRequested, !handoffRequested else { return }
        handoffRequested = true
        pendingHandoff = (handoffGeneration, pendingWriteTask, onLocationKept)
        guard handoffTask == nil else { return }
        handoffTask = Task { [weak self] in
            await self?.drainHandoff()
        }
    }

    private func drainHandoff() async {
        defer { handoffTask = nil }
        while let request = pendingHandoff {
            await request.drain?.value
            guard pendingHandoff?.generation == request.generation else { continue }
            pendingHandoff = nil
            guard request.generation == handoffGeneration else { continue }
            request.kept?()
        }
    }

    /// 等待已请求的定点接管，不清除设备模拟；未请求接管时直接返回。
    func waitForHandoff() async {
        await handoffTask?.value
    }

    private func beginRouteKeepAlive() {
        BackgroundKeepAlive.shared.retain(.routePlayback)
    }

    private func endRouteKeepAlive() {
        BackgroundKeepAlive.shared.release(.routePlayback)
    }
}
