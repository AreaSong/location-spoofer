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
    @Published private(set) var phase: RoutePhase = .inactive
    @Published var travelMode: RouteTravelMode = .walk
    @Published private(set) var start: CoordinatePair?
    @Published private(set) var end: CoordinatePair?
    @Published private(set) var path: RoutePath?
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: CoordinatePair?
    @Published private(set) var waitingForActivation = false
    @Published private(set) var isRouting = false
    @Published var statusMessage = ""

    var applyCoordinate: ((CoordinatePair) async -> Bool)?
    var tickIntervalNanoseconds: UInt64 = 1_000_000_000

    private var elapsed: TimeInterval = 0
    private var playbackTask: Task<Void, Never>?
    private var pathGeneration: UInt64 = 0

    var canPlay: Bool {
        (path?.totalMeters ?? distanceMeters) >= RoutePlayback.minimumDistanceMeters
    }

    var distanceMeters: Double {
        if let path, path.totalMeters > 0 { return path.totalMeters }
        guard let start, let end else { return 0 }
        return RoutePlayback.distanceMeters(from: start, to: end)
    }

    var overlayCoordinates: [CLLocationCoordinate2D] {
        let system = CoordinateConverter.currentMapCoordinateSystem
        if let path, path.points.count >= 2 {
            return path.points.map { $0.coordinate(for: system) }
        }
        guard let start, let end else { return [] }
        return [start.coordinate(for: system), end.coordinate(for: system)]
    }

    var progressCoordinate: CLLocationCoordinate2D? {
        guard phase != .inactive else { return nil }
        let system = CoordinateConverter.currentMapCoordinateSystem
        return (current ?? start)?.coordinate(for: system)
    }

    func enter(start pair: CoordinatePair) {
        stopPlaybackTask()
        pathGeneration &+= 1
        start = pair
        end = nil
        path = nil
        current = pair
        progress = 0
        elapsed = 0
        waitingForActivation = false
        isRouting = false
        statusMessage = "移动地图到终点，然后点「终点」。"
        phase = .preparing
    }

    func setStart(_ pair: CoordinatePair) {
        start = pair
        if current == nil { current = pair }
        Task { await rebuildPath() }
    }

    func setEnd(_ pair: CoordinatePair) {
        end = pair
        Task { await rebuildPath() }
    }

    func requestPlay() {
        guard canPlay else {
            statusMessage = "起点和终点太近，请再拉开一些。"
            return
        }
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
        waitingForActivation = false
        isRouting = false
        start = nil
        end = nil
        path = nil
        current = nil
        progress = 0
        elapsed = 0
        statusMessage = ""
        phase = .inactive
    }

    func refreshReadyMessage() {
        guard start != nil, end != nil else {
            statusMessage = "移动地图到终点，然后点「终点」。"
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
        statusMessage = "\(RoutePlayback.formattedDistance(meters))，\(RoutePlayback.formattedDuration(meters: meters, mode: travelMode))"
    }

    func rebuildPath() async {
        guard let start, let end else {
            path = nil
            refreshReadyMessage()
            return
        }
        path = RoutePath.make([start, end])
        pathGeneration &+= 1
        let generation = pathGeneration
        isRouting = true
        refreshReadyMessage()
        let routed = await RouteDirections.waypoints(from: start, to: end, mode: travelMode)
        guard generation == pathGeneration else { return }
        path = RoutePath.make(routed)
        isRouting = false
        refreshReadyMessage()
    }

    private func startLoop() {
        stopPlaybackTask()
        BackgroundKeepAlive.shared.start()
        phase = .playing
        statusMessage = "正在沿路移动，可切到地图查看。"
        playbackTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        let origin = Date().addingTimeInterval(-elapsed)
        while !Task.isCancelled, phase == .playing, let path, path.points.count >= 2 {
            elapsed = Date().timeIntervalSince(origin)
            let tick = RoutePlayback.tick(path: path, mode: travelMode, elapsed: elapsed)
            current = tick.coordinatePair
            progress = tick.progress
            let applied = await applyCoordinate?(tick.coordinatePair) ?? false
            if !applied {
                pause()
                statusMessage = "写入坐标失败，已暂停。"
                return
            }
            if tick.isFinished {
                phase = .finished
                statusMessage = "已到达终点，虚拟定位停在终点。"
                return
            }
            try? await Task.sleep(nanoseconds: tickIntervalNanoseconds)
        }
    }

    private func stopPlaybackTask() {
        playbackTask?.cancel()
        playbackTask = nil
    }
}
