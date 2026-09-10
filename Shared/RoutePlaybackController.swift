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
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: CoordinatePair?
    @Published private(set) var waitingForActivation = false
    @Published var statusMessage = ""

    var applyCoordinate: ((CoordinatePair) async -> Bool)?
    var tickIntervalNanoseconds: UInt64 = 1_000_000_000

    private var elapsed: TimeInterval = 0
    private var playbackTask: Task<Void, Never>?

    var canPlay: Bool {
        guard let start, let end else { return false }
        return RoutePlayback.distanceMeters(from: start, to: end) >= RoutePlayback.minimumDistanceMeters
    }

    var distanceMeters: Double {
        guard let start, let end else { return 0 }
        return RoutePlayback.distanceMeters(from: start, to: end)
    }

    var overlayCoordinates: [CLLocationCoordinate2D] {
        guard let start, let end else { return [] }
        let system = CoordinateConverter.currentMapCoordinateSystem
        return [
            start.coordinate(for: system),
            end.coordinate(for: system)
        ]
    }

    func enter(start pair: CoordinatePair) {
        stopPlaybackTask()
        start = pair
        end = nil
        current = pair
        progress = 0
        elapsed = 0
        waitingForActivation = false
        statusMessage = "移动地图到终点，然后点「设为终点」。"
        phase = .preparing
    }

    func setStart(_ pair: CoordinatePair) {
        start = pair
        refreshReadyMessage()
    }

    func setEnd(_ pair: CoordinatePair) {
        end = pair
        refreshReadyMessage()
    }

    func requestPlay() {
        guard canPlay else {
            statusMessage = "起点和终点太近，请再拉开一些。"
            return
        }
        elapsed = 0
        progress = 0
        current = start
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
        statusMessage = "已暂停。回到前台后可继续。"
    }

    func resume() {
        guard phase == .paused, canPlay else { return }
        startLoop()
    }

    func exit() {
        stopPlaybackTask()
        waitingForActivation = false
        start = nil
        end = nil
        current = nil
        progress = 0
        elapsed = 0
        statusMessage = ""
        phase = .inactive
    }

    func refreshReadyMessage() {
        guard let start, let end else {
            statusMessage = "移动地图到终点，然后点「设为终点」。"
            return
        }
        let meters = RoutePlayback.distanceMeters(from: start, to: end)
        guard meters >= RoutePlayback.minimumDistanceMeters else {
            statusMessage = "起点和终点太近，请再拉开一些。"
            return
        }
        statusMessage = "\(RoutePlayback.formattedDistance(meters))，\(RoutePlayback.formattedDuration(meters: meters, mode: travelMode))"
    }

    private func startLoop() {
        stopPlaybackTask()
        phase = .playing
        statusMessage = "路线播放中，请保持 App 在前台。"
        playbackTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        let origin = Date().addingTimeInterval(-elapsed)
        while !Task.isCancelled, phase == .playing, let start, let end {
            elapsed = Date().timeIntervalSince(origin)
            let tick = RoutePlayback.tick(from: start, to: end, mode: travelMode, elapsed: elapsed)
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
