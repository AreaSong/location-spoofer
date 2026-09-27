import Combine
import CoreMotion
import Foundation

enum PhysicalWalkStatus: Equatable {
    case idle
    case waitingForHeading
    case tracking
}

@MainActor
final class PhysicalWalkController: ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var status: PhysicalWalkStatus = .idle
    @Published private(set) var movedMeters = 0.0

    var ignoresWriteGate = false
    var applyCoordinate: ((CoordinatePair) async -> Bool)?
    var onFailure: ((String) -> Void)?

    private let sensor: PhysicalWalkSensing
    private let heading: PhysicalWalkHeadingSensing
    private let keepAlive: BackgroundKeepAlive
    private var engine: PhysicalWalkEngine?
    private var writeGate = RouteWriteGate()
    private var generation: UInt64 = 0
    private var writeTask: Task<Void, Never>?

    init(
        sensor: PhysicalWalkSensing? = nil,
        heading: PhysicalWalkHeadingSensing? = nil,
        keepAlive: BackgroundKeepAlive = .shared
    ) {
        self.sensor = sensor ?? CoreMotionPedometerDriver()
        self.heading = heading ?? CoreLocationHeadingDriver()
        self.keepAlive = keepAlive
    }

    func start(latitude: Double, longitude: Double) {
        guard !isTracking else { return }
        if let message = availabilityMessage() {
            fail(message)
            return
        }
        generation &+= 1
        let generation = generation
        engine = PhysicalWalkEngine(latitude: latitude, longitude: longitude)
        writeGate.reset()
        movedMeters = 0
        isTracking = true
        status = .waitingForHeading
        keepAlive.retain(.physicalWalk)
        heading.start()
        sensor.start(from: Date()) { [weak self] sample, error in
            self?.handleUpdate(sample: sample, error: error, generation: generation)
        }
        RuntimeLogger.info("APP", "真实走动", "开始跟踪", details: [
            "纬度": String(latitude),
            "经度": String(longitude)
        ])
    }

    func stop() {
        generation &+= 1
        writeTask?.cancel()
        writeTask = nil
        tearDownSensors()
        engine = nil
        let wasTracking = isTracking
        isTracking = false
        status = .idle
        if wasTracking {
            RuntimeLogger.info("APP", "真实走动", "停止跟踪")
        }
    }

    func ingest(sample: PhysicalWalkSample, at now: Date = Date()) async {
        guard isTracking else { return }
        if case .moved = apply(sample: sample) {
            await considerWrite(at: now)
        }
    }

    private func handleUpdate(sample: PhysicalWalkSample?, error: Error?, generation: UInt64) {
        guard generation == self.generation, isTracking else { return }
        if let error {
            fail(Self.message(for: error))
            return
        }
        guard let sample else { return }
        if case .moved = apply(sample: sample) {
            writeTask = Task { [weak self] in
                await self?.considerWrite(at: Date())
            }
        }
    }

    @discardableResult
    private func apply(sample: PhysicalWalkSample) -> PhysicalWalkApplyResult {
        guard var engine else { return .unchanged }
        let result = engine.apply(sample: sample, heading: heading.latest)
        self.engine = engine
        movedMeters = engine.movedMeters
        switch result {
        case .unchanged:
            break
        case .waitingForHeading:
            status = .waitingForHeading
        case .moved:
            status = .tracking
        }
        return result
    }

    private func considerWrite(at now: Date) async {
        guard isTracking, let engine else { return }
        let pair = CoordinateConverter.coordinatePair(
            lat: engine.latitude,
            lon: engine.longitude,
            mapCoordinateSystem: .wgs84
        )
        guard ignoresWriteGate || writeGate.shouldWrite(pair, at: now, force: false) else { return }
        let applied = await applyCoordinate?(pair) ?? false
        guard isTracking else { return }
        if applied {
            writeGate.markWritten(pair, at: now)
        }
    }

    private func availabilityMessage() -> String? {
        guard sensor.isStepCountingAvailable else {
            return "这台设备不支持计步，无法使用真实走动。"
        }
        if sensor.authorizationStatus() == .denied {
            return "需要运动与健身权限才能真实走动。"
        }
        guard heading.headingAvailable else {
            return "这台设备没有罗盘，无法按朝向移动虚拟定位。"
        }
        return nil
    }

    private func fail(_ message: String) {
        RuntimeLogger.warning("APP", "真实走动", message)
        stop()
        onFailure?(message)
    }

    private func tearDownSensors() {
        sensor.stop()
        heading.stop()
        keepAlive.release(.physicalWalk)
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == CMErrorDomain {
            return "需要运动与健身权限才能真实走动。"
        }
        return "真实走动无法读取步伐，请稍后重试。"
    }
}
