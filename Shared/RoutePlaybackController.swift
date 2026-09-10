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

    @Published private(set) var phase: RoutePhase = .inactive
    @Published var travelMode: RouteTravelMode
    @Published var speedKilometersPerHour: Double
    @Published var offsetMeters: Double
    @Published var repeatMode: RouteRepeatMode
    @Published private(set) var start: CoordinatePair?
    @Published private(set) var end: CoordinatePair?
    @Published private(set) var vias: [CoordinatePair] = []
    @Published private(set) var path: RoutePath?
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: CoordinatePair?
    @Published private(set) var waitingForActivation = false
    @Published private(set) var isRouting = false
    @Published private(set) var pathRevision: UInt64 = 0
    @Published var statusMessage = ""

    var applyCoordinate: ((CoordinatePair) async -> Bool)?
    var tickIntervalNanoseconds: UInt64 = 1_000_000_000

    private(set) var headingForward = true
    private var elapsed: TimeInterval = 0
    private var playbackTask: Task<Void, Never>?
    private var pathGeneration: UInt64 = 0
    private let preferenceStore: RoutePlaybackPreferenceStore

    init(preferenceStore: RoutePlaybackPreferenceStore = RoutePlaybackPreferenceStore()) {
        self.preferenceStore = preferenceStore
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

    var canAddVia: Bool {
        start != nil && vias.count < Self.maxViaCount && phase == .preparing
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

    var progressCoordinate: CLLocationCoordinate2D? {
        switch phase {
        case .playing, .paused, .finished:
            let system = CoordinateConverter.currentMapCoordinateSystem
            return (current ?? start)?.coordinate(for: system)
        case .inactive, .preparing:
            return nil
        }
    }

    func enter(start pair: CoordinatePair? = nil) {
        stopPlaybackTask()
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
        refreshReadyMessage()
        phase = .preparing
    }

    func load(_ saved: SavedRoute) {
        stopPlaybackTask()
        pathGeneration &+= 1
        headingForward = true
        waitingForActivation = false
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
        persistPreferences()
        if let points = saved.pathPoints, points.count >= 2 {
            path = RoutePath.make(points)
            current = path?.points.first ?? saved.start
            isRouting = false
            refreshReadyMessage()
            bumpPathRevision()
            return
        }
        path = nil
        current = saved.start
        isRouting = false
        Task { await rebuildPath() }
    }

    func makeSavedRoute(name: String) -> SavedRoute? {
        guard let start, let end, canPlay, !isRouting else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = path?.points
        return SavedRoute(
            name: trimmed.isEmpty ? RoutePlayback.formattedDistance(distanceMeters) : trimmed,
            start: start,
            end: end,
            travelMode: travelMode,
            speedKilometersPerHour: speedKilometersPerHour,
            offsetMeters: offsetMeters,
            repeatMode: repeatMode,
            viaPoints: vias,
            pathPoints: (points?.count ?? 0) >= 2 ? points : nil
        )
    }

    func setStart(_ pair: CoordinatePair) {
        start = pair
        current = pair
        Task { await rebuildPath() }
    }

    func setEnd(_ pair: CoordinatePair) {
        end = pair
        Task { await rebuildPath() }
    }

    func addVia(_ pair: CoordinatePair) {
        guard canAddVia, let start else { return }
        let previous = vias.last ?? start
        guard RoutePlayback.distanceMeters(from: previous, to: pair) >= RoutePlayback.minimumDistanceMeters else {
            statusMessage = "途经点和上一个点太近，请再拉开一些。"
            return
        }
        vias.append(pair)
        Task { await rebuildPath() }
    }

    func removeLastVia() {
        guard phase == .preparing, !vias.isEmpty else { return }
        vias.removeLast()
        Task { await rebuildPath() }
    }

    func reverseDirection() {
        guard canReverse, let start, let end else { return }
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

    func noteActivated() {
        guard waitingForActivation else { return }
        waitingForActivation = false
        startLoop()
    }

    func cancelWaiting() {
        waitingForActivation = false
        if phase == .playing { return }
        if phase != .inactive {
            phase = .preparing
            statusMessage = "未能开启虚拟定位，路线仍可修改。"
        }
    }

    func pause() {
        guard phase == .playing else { return }
        stopPlaybackTask()
        phase = .paused
        statusMessage = "已暂停。"
    }

    func resume() {
        guard phase == .paused, canPlay else { return }
        startLoop()
    }

    func exit() {
        stopPlaybackTask()
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
        phase = .inactive
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
        speedKilometersPerHour = min(40, max(1, value))
        persistPreferences()
        refreshReadyMessage()
    }

    func setOffsetMeters(_ value: Double) {
        offsetMeters = min(80, max(0, value))
        persistPreferences()
    }

    func applyTravelMode(_ mode: RouteTravelMode) {
        travelMode = mode
        speedKilometersPerHour = mode.kilometersPerHour
        persistPreferences()
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
            refreshReadyMessage()
            return
        }
        path = RoutePath.make(points)
        pathGeneration &+= 1
        let generation = pathGeneration
        isRouting = true
        refreshReadyMessage()
        let routed = await RouteDirections.waypoints(along: points, mode: travelMode)
        guard generation == pathGeneration else { return }
        path = RoutePath.make(routed)
        isRouting = false
        refreshReadyMessage()
        bumpPathRevision()
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
        BackgroundKeepAlive.shared.start()
        phase = .playing
        statusMessage = playbackStatusMessage()
        playbackTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        var origin = Date().addingTimeInterval(-elapsed)
        while !Task.isCancelled, phase == .playing {
            guard let basePath = path, basePath.points.count >= 2 else { break }
            let activePath = headingForward ? basePath : basePath.reversed()
            elapsed = Date().timeIntervalSince(origin)
            let tick = RoutePlayback.tick(
                path: activePath,
                speedMetersPerSecond: speedMetersPerSecond,
                elapsed: elapsed
            )
            current = tick.coordinatePair
            progress = tick.progress
            let applied = await applyCoordinate?(tick.coordinatePair) ?? false
            if !applied {
                pause()
                statusMessage = "写入坐标失败，已暂停。"
                return
            }
            if tick.isFinished {
                if handleFinishedLeg() {
                    phase = .finished
                    statusMessage = finishedStatusMessage()
                    return
                }
                origin = Date()
                elapsed = 0
                progress = 0
                statusMessage = playbackStatusMessage()
                continue
            }
            statusMessage = playbackStatusMessage()
            try? await Task.sleep(nanoseconds: tickIntervalNanoseconds)
        }
    }

    private func readyStatusMessage(meters: Double) -> String {
        var prefix = RoutePlayback.formattedDistance(meters)
        if !vias.isEmpty {
            prefix += " · \(vias.count) 个途经"
        }
        let durationText = RoutePlayback.formattedDuration(
            meters: meters,
            speedMetersPerSecond: speedMetersPerSecond
        )
        switch repeatMode {
        case .once:
            return "\(prefix)，\(durationText)"
        case .roundTrip:
            let roundMeters = meters * 2
            return "往返 \(RoutePlayback.formattedDistance(roundMeters))，\(RoutePlayback.formattedDuration(meters: roundMeters, speedMetersPerSecond: speedMetersPerSecond))"
        case .loop:
            return "\(prefix)，循环走，直到暂停"
        }
    }

    private func playbackStatusMessage() -> String {
        let remaining = RoutePlayback.formattedRemaining(
            meters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond
        )
        if !headingForward {
            return "走回起点 · \(remaining)"
        }
        if repeatMode == .loop {
            return "循环中 · \(remaining)"
        }
        if repeatMode == .roundTrip {
            return "走向终点 · \(remaining)"
        }
        return "正在从起点沿路走到终点。\(remaining)"
    }

    private func finishedStatusMessage() -> String {
        if headingForward {
            return "已走到终点。你的虚拟定位现在停在这里。"
        }
        return "已走回起点。你的虚拟定位现在停在这里。"
    }

    private func bumpPathRevision() {
        pathRevision &+= 1
    }

    private func persistPreferences() {
        preferenceStore.save(
            RoutePlaybackPreferences(
                travelMode: travelMode,
                speedKilometersPerHour: speedKilometersPerHour,
                offsetMeters: offsetMeters,
                repeatMode: repeatMode
            )
        )
    }

    private func stopPlaybackTask() {
        playbackTask?.cancel()
        playbackTask = nil
    }
}
