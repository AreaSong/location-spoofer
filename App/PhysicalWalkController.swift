import Combine
import CoreMotion
import Foundation

@MainActor
final class PhysicalWalkController: ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var status: PhysicalWalkStatus = .idle
    @Published private(set) var movedMeters = 0.0
    @Published private(set) var currentLatitude: Double?
    @Published private(set) var currentLongitude: Double?
    @Published private(set) var headingMode: PhysicalWalkHeadingMode = .followCompass
    @Published private(set) var usesCustomHeading = false
    @Published private(set) var initialHeadingDegrees: Double = 0
    @Published private(set) var activeHeadingDegrees: Double? = 0

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
    private var headingInstrument = PhysicalWalkHeadingInstrument.north
    private var didBindSensorZero = false

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
        currentLatitude = latitude
        currentLongitude = longitude
        isTracking = true
        status = .tracking
        publishActiveHeading()
        keepAlive.retain(.physicalWalk)
        attachHeadingHandler(appliesWalk: true)
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
        sensor.stop()
        engine = nil
        currentLatitude = nil
        currentLongitude = nil
        let wasTracking = isTracking
        isTracking = false
        status = .idle
        keepAlive.release(.physicalWalk)
        attachHeadingHandler(appliesWalk: false)
        publishActiveHeading()
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

    func applyPersistedInitial(_ degrees: Double) {
        headingInstrument.initialDegrees = PhysicalWalkHeadingLock.normalized(degrees)
        initialHeadingDegrees = headingInstrument.initialDegrees
        if usesCustomHeading {
            headingMode = .locked(degrees: headingInstrument.initialDegrees)
        }
        publishActiveHeading()
    }

    func setCustomHeadingEnabled(_ enabled: Bool) {
        if usesCustomHeading == enabled {
            headingMode = enabled ? .locked(degrees: headingInstrument.initialDegrees) : .followCompass
            publishActiveHeading()
            return
        }
        usesCustomHeading = enabled
        if enabled {
            recaptureInstrumentZero()
            headingMode = .locked(degrees: headingInstrument.initialDegrees)
        } else {
            headingMode = .followCompass
        }
        publishActiveHeading()
        flushHeading()
    }

    func lockHeading(degrees: Double) {
        recaptureInstrumentZero(initialDegrees: degrees)
        initialHeadingDegrees = headingInstrument.initialDegrees
        if usesCustomHeading {
            headingMode = .locked(degrees: headingInstrument.initialDegrees)
        }
        publishActiveHeading()
        if usesCustomHeading {
            flushHeading()
        }
    }

    func startHeadingPreview() {
        attachHeadingHandler(appliesWalk: isTracking)
        heading.start()
        publishActiveHeading()
    }

    func stopHeading() {
        heading.onChange = nil
        heading.stop()
        didBindSensorZero = false
    }

    func rotateLockedHeading(by delta: Double) {
        guard usesCustomHeading else { return }
        lockHeading(degrees: (activeHeadingDegrees ?? initialHeadingDegrees) + delta)
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
        publishActiveHeading()
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
        let result = engine.apply(sample: sample, heading: resolvedHeading())
        self.engine = engine
        movedMeters = engine.movedMeters
        currentLatitude = engine.latitude
        currentLongitude = engine.longitude
        publishActiveHeading()
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

    private func attachHeadingHandler(appliesWalk: Bool) {
        heading.onChange = { [weak self] in
            self?.bindSensorZeroIfNeeded()
            if appliesWalk {
                self?.flushHeading()
            } else {
                self?.publishActiveHeading()
            }
        }
    }

    private func bindSensorZeroIfNeeded() {
        guard usesCustomHeading, !didBindSensorZero, let yaw = heading.latestYawDegrees else { return }
        headingInstrument.referenceYawDegrees = yaw
        didBindSensorZero = true
    }

    private func recaptureInstrumentZero(initialDegrees: Double? = nil) {
        let yaw = heading.latestYawDegrees ?? headingInstrument.referenceYawDegrees
        headingInstrument = PhysicalWalkHeadingInstrument.capturingInitial(
            initialDegrees ?? headingInstrument.initialDegrees,
            currentYawDegrees: yaw
        )
        didBindSensorZero = heading.latestYawDegrees != nil
    }

    private func resolvedHeading() -> PhysicalWalkHeading? {
        if usesCustomHeading {
            let yaw = heading.latestYawDegrees ?? headingInstrument.referenceYawDegrees
            let degrees = headingInstrument.liveDegrees(currentYawDegrees: yaw)
            return PhysicalWalkHeading(degrees: degrees, accuracyDegrees: 0)
        }
        if let map = heading.latestMapHeadingDegrees {
            return PhysicalWalkHeading(degrees: map, accuracyDegrees: 0)
        }
        if let yaw = heading.latestYawDegrees {
            return PhysicalWalkHeading(degrees: yaw, accuracyDegrees: 0)
        }
        return PhysicalWalkHeading(degrees: 0, accuracyDegrees: 0)
    }

    private func publishActiveHeading() {
        activeHeadingDegrees = resolvedHeading()?.degrees
        initialHeadingDegrees = headingInstrument.initialDegrees
    }

    private func fail(_ message: String) {
        RuntimeLogger.warning("APP", "真实走动", message)
        stop()
        startHeadingPreview()
        onFailure?(message)
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
