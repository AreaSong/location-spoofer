import Combine
import CoreMotion
import Foundation

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
        self.heading = heading ?? PhysicalWalkHeadingDriver()
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
        heading.onChange = { [weak self] in
            self?.flushHeading()
        }
        heading.start()
        sensor.requestAuthorization { [weak self] status in
            self?.continueStart(
                after: status,
                generation: generation,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    func stop() {
        generation &+= 1
        writeTask?.cancel()
        writeTask = nil
        heading.onChange = nil
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

    private func continueStart(
        after status: PhysicalWalkAuthorization,
        generation: UInt64,
        latitude: Double,
        longitude: Double
    ) {
        guard generation == self.generation, isTracking else { return }
        if status == .denied {
            fail(PhysicalWalkSensorPolicy.permissionDeniedMessage)
            return
        }
        sensor.start(from: Date()) { [weak self] sample, error in
            self?.handleUpdate(sample: sample, error: error, generation: generation)
        }
        RuntimeLogger.info("APP", "真实走动", "开始跟踪", details: [
            "纬度": String(latitude),
            "经度": String(longitude)
        ])
    }

    private func handleUpdate(sample: PhysicalWalkSample?, error: Error?, generation: UInt64) {
        guard generation == self.generation, isTracking else { return }
        if let error {
            handleSensorError(error)
            return
        }
        guard let sample else { return }
        if case .moved = apply(sample: sample) {
            writeTask = Task { [weak self] in
                await self?.considerWrite(at: Date())
            }
        }
    }

    private func handleSensorError(_ error: Error) {
        switch PhysicalWalkSensorPolicy.action(
            forAuthorization: sensor.authorizationStatus(),
            isAuthorizationError: Self.isMotionAuthorizationError(error)
        ) {
        case .ignore:
            return
        case let .fail(message):
            fail(message)
        }
    }

    private func flushHeading() {
        guard isTracking else { return }
        if case .moved = apply(sample: PhysicalWalkSample()) {
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
        PhysicalWalkSensorPolicy.availabilityMessage(
            stepCountingAvailable: sensor.isStepCountingAvailable,
            authorization: sensor.authorizationStatus(),
            headingAvailable: heading.headingAvailable
        )
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

    private static func isMotionAuthorizationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == CMErrorDomain else { return false }
        switch nsError.code {
        case Int(CMErrorMotionActivityNotAuthorized.rawValue),
             Int(CMErrorNotAuthorized.rawValue):
            return true
        default:
            return false
        }
    }
}
