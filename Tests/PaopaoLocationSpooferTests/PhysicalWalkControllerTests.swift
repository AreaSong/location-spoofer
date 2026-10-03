import CoreMotion
import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class PhysicalWalkStoreTests: XCTestCase {
    func testDefaultsToDisabledAndPersistsChanges() {
        let suite = "PhysicalWalkStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PhysicalWalkStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isCustomHeadingEnabled)
        XCTAssertEqual(store.initialHeadingDegrees, 0, accuracy: 0.01)
        XCTAssertEqual(store.lastFailureMessage, "")
        XCTAssertEqual(store.strideMeters, PhysicalWalkDisplacement.defaultStrideMeters, accuracy: 0.000_1)

        store.setEnabled(true)
        store.setCustomHeadingEnabled(true)
        store.setInitialHeadingDegrees(92)
        store.setStrideMeters(0.9)
        let restored = PhysicalWalkStore(defaults: defaults)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertTrue(restored.isCustomHeadingEnabled)
        XCTAssertEqual(restored.initialHeadingDegrees, 92, accuracy: 0.01)
        XCTAssertEqual(restored.strideMeters, 0.9, accuracy: 0.000_1)

        store.setStrideMeters(0.2)
        XCTAssertEqual(store.strideMeters, PhysicalWalkDisplacement.minimumStrideMeters, accuracy: 0.000_1)
        store.setStrideMeters(2)
        XCTAssertEqual(store.strideMeters, PhysicalWalkDisplacement.maximumStrideMeters, accuracy: 0.000_1)

        store.noteFailure("需要运动与健身权限才能真实走动。")
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.lastFailureMessage, "需要运动与健身权限才能真实走动。")

        store.clearFailure()
        XCTAssertEqual(store.lastFailureMessage, "")
        XCTAssertFalse(store.isEnabled)
    }
}

@MainActor
final class PhysicalWalkControllerTests: XCTestCase {
    override func tearDown() {
        BackgroundKeepAlive.shared.stop()
        super.tearDown()
    }

    func testSlowWriteCoalescesCumulativeSamples() async {
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: FakePhysicalWalkHeading())
        controller.ignoresWriteGate = true
        let started = expectation(description: "首笔写入挂起")
        var release: CheckedContinuation<Void, Never>?
        var writes: [CoordinatePair] = []
        controller.applyCoordinate = { pair in
            writes.append(pair)
            if writes.count == 1 {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
            return true
        }
        controller.start(latitude: 1, longitude: 2)
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0))
        let first = Task { await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 10, steps: 0)) }
        await fulfillment(of: [started], timeout: 2)
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 20, steps: 0))
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 30, steps: 0))
        XCTAssertEqual(writes.count, 1, "慢写入期间只保留一个最新累计位置")
        release?.resume()
        await first.value
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(controller.movedMeters, 30, accuracy: 0.01)
        XCTAssertEqual(writes.last?.wgs84.latitude ?? 0, controller.currentLatitude ?? 0, accuracy: 0.0000001)
        controller.stop()
    }

    func testSensorBurstKeepsOnePendingCumulativePosition() async {
        let sensor = FakePhysicalWalkSensor()
        let controller = PhysicalWalkController(sensor: sensor, heading: FakePhysicalWalkHeading())
        controller.ignoresWriteGate = true
        let entered = expectation(description: "传感器首笔已发送")
        let last = expectation(description: "合并后的累计位置已写入")
        var release: CheckedContinuation<Void, Never>?
        var writes: [CoordinatePair] = []
        controller.applyCoordinate = { pair in
            writes.append(pair)
            if writes.count == 1 {
                await withCheckedContinuation { release = $0; entered.fulfill() }
            } else { last.fulfill() }
            return true
        }
        controller.start(latitude: 1, longitude: 2)
        sensor.emit(sample: .init(distanceMeters: 0, steps: 0))
        sensor.emit(sample: .init(distanceMeters: 10, steps: 0))
        await fulfillment(of: [entered], timeout: 2)
        for meters in 11...1010 { sensor.emit(sample: .init(distanceMeters: Double(meters), steps: 0)) }
        XCTAssertEqual(writes.count, 1)
        release?.resume()
        await fulfillment(of: [last], timeout: 2)
        await controller.stop()?.value
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(controller.movedMeters, 1010, accuracy: 0.01)
        let expected = PhysicalWalkDisplacement.offsetWGS84(latitude: 1, longitude: 2, distanceMeters: 1010, headingDegrees: 0)
        XCTAssertEqual(writes.last?.wgs84.latitude ?? 0, expected.latitude, accuracy: 1e-8)
    }

    func testTenMeterWalkWritesTheDisplacedCoordinate() async throws {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 0
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var written: CoordinatePair?
        controller.applyCoordinate = { pair in
            written = pair
            return true
        }
        let originLatitude = 22.494
        let originLongitude = 113.951
        controller.start(latitude: originLatitude, longitude: originLongitude)

        XCTAssertTrue(controller.isTracking)
        XCTAssertTrue(BackgroundKeepAlive.shared.holds(.physicalWalk))

        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0))
        XCTAssertNil(written)

        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 10, steps: 12))
        let pair = try XCTUnwrap(written)
        let distance = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: pair.wgs84.latitude,
            lon2: pair.wgs84.longitude
        )
        XCTAssertEqual(distance, 10, accuracy: 0.5)
        XCTAssertEqual(controller.status, .tracking)

        controller.stop()
        XCTAssertFalse(controller.isTracking)
        XCTAssertFalse(BackgroundKeepAlive.shared.holds(.physicalWalk))
    }

    func testFrozenPedometerDistanceStillWritesUsingSteps() async throws {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 0
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var written: CoordinatePair?
        controller.applyCoordinate = { pair in
            written = pair
            return true
        }
        let originLatitude = 22.494
        let originLongitude = 113.951
        controller.start(latitude: originLatitude, longitude: originLongitude)

        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0))
        XCTAssertNil(written)
        XCTAssertEqual(controller.currentLatitude ?? 0, originLatitude, accuracy: 0.000_000_1)

        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 10))
        let pair = try XCTUnwrap(written)
        let distance = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: pair.wgs84.latitude,
            lon2: pair.wgs84.longitude
        )
        XCTAssertEqual(distance, 7.4, accuracy: 0.5)
        XCTAssertGreaterThan(controller.currentLatitude ?? originLatitude, originLatitude)
        controller.stop()
        XCTAssertNil(controller.currentLatitude)
    }

    func testLockedEastHeadingMovesEastEvenWhenCompassPointsNorth() async throws {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 0
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var written: CoordinatePair?
        controller.applyCoordinate = { pair in
            written = pair
            return true
        }
        let originLatitude = 22.494
        let originLongitude = 113.951
        controller.start(latitude: originLatitude, longitude: originLongitude)
        controller.setCustomHeadingEnabled(true)
        controller.lockHeading(degrees: 90)

        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0))
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 10, steps: 12))
        let pair = try XCTUnwrap(written)
        XCTAssertEqual(pair.wgs84.latitude, originLatitude, accuracy: 0.000_01)
        XCTAssertGreaterThan(pair.wgs84.longitude, originLongitude)
        XCTAssertEqual(controller.headingMode, .locked(degrees: 90))
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 90, accuracy: 0.01)
        controller.stop()
    }

    func testDeniedAuthorizationDoesNotWrite() {
        let sensor = FakePhysicalWalkSensor()
        sensor.authorization = .denied
        let heading = FakePhysicalWalkHeading()
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var failure = ""
        var wrote = false
        controller.onFailure = { failure = $0 }
        controller.applyCoordinate = { _ in
            wrote = true
            return true
        }

        controller.start(latitude: 22.494, longitude: 113.951)

        XCTAssertFalse(controller.isTracking)
        XCTAssertFalse(wrote)
        XCTAssertEqual(failure, "需要运动与健身权限才能真实走动。")
        XCTAssertFalse(BackgroundKeepAlive.shared.holds(.physicalWalk))
    }

    func testBufferedWalkWritesWhenHeadingBecomesReliable() async {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 0
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var wrote = false
        controller.applyCoordinate = { _ in
            wrote = true
            return true
        }
        controller.start(latitude: 22.494, longitude: 113.951)
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0))
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 10, steps: 12))

        XCTAssertTrue(wrote)
        XCTAssertEqual(controller.status, .tracking)
        controller.stop()
    }

    func testPrematureAuthorizationErrorDoesNotFailWhilePromptIsOpen() {
        let sensor = FakePhysicalWalkSensor()
        sensor.authorization = .notDetermined
        let heading = FakePhysicalWalkHeading()
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var failure = ""
        controller.onFailure = { failure = $0 }

        controller.start(latitude: 22.494, longitude: 113.951)
        sensor.emit(error: Self.motionAuthorizationError)

        XCTAssertTrue(controller.isTracking)
        XCTAssertEqual(failure, "")
        controller.stop()
    }

    func testDeniedAfterPromptFailsWithPermissionMessage() {
        let sensor = FakePhysicalWalkSensor()
        sensor.authorization = .notDetermined
        let heading = FakePhysicalWalkHeading()
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var failure = ""
        controller.onFailure = { failure = $0 }

        controller.start(latitude: 22.494, longitude: 113.951)
        sensor.authorization = .denied
        sensor.emit(error: Self.motionAuthorizationError)

        XCTAssertFalse(controller.isTracking)
        XCTAssertEqual(failure, PhysicalWalkSensorPolicy.permissionDeniedMessage)
        XCTAssertFalse(BackgroundKeepAlive.shared.holds(.physicalWalk))
    }

    func testHeadingPreviewFollowsYawDeltaFromInitial() {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 10
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)

        controller.startHeadingPreview()
        controller.setCustomHeadingEnabled(true)
        controller.lockHeading(degrees: 180)
        XCTAssertEqual(controller.initialHeadingDegrees, 180, accuracy: 0.01)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 180, accuracy: 0.01)

        heading.latestYawDegrees = 190
        heading.onChange?()
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(controller.initialHeadingDegrees, 180, accuracy: 0.01)

        heading.latestYawDegrees = 10
        heading.onChange?()
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 180, accuracy: 0.01)
        controller.stopHeading()
    }

    func testRotateLockedHeadingStepsByFifteenDegrees() {
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 0
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)
        controller.setCustomHeadingEnabled(true)
        controller.lockHeading(degrees: 270)
        controller.rotateLockedHeading(by: -15)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 255, accuracy: 0.01)
        XCTAssertEqual(controller.initialHeadingDegrees, 255, accuracy: 0.01)
        XCTAssertEqual(controller.headingMode, .locked(degrees: 255))
        controller.stopHeading()
    }

    func testHeadingPreviewKeepsInitialNorthWhenAttitudeIsMissing() {
        let heading = FakePhysicalWalkHeading()
        heading.headingAvailable = false
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)
        controller.startHeadingPreview()
        XCTAssertEqual(controller.headingMode, .followCompass)
        XCTAssertFalse(controller.usesCustomHeading)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 0, accuracy: 0.01)
        controller.stopHeading()
    }

    func testMapHeadingDrivesFanWhenCustomHeadingIsOff() {
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 10
        heading.latestMapHeadingDegrees = 180
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)

        controller.applyPersistedInitial(92)
        controller.startHeadingPreview()
        XCTAssertFalse(controller.usesCustomHeading)
        XCTAssertEqual(controller.headingMode, .followCompass)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 180, accuracy: 0.01)
        XCTAssertEqual(controller.initialHeadingDegrees, 92, accuracy: 0.01)

        heading.latestYawDegrees = 90
        heading.onChange?()
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 180, accuracy: 0.01)

        heading.latestMapHeadingDegrees = 45
        heading.onChange?()
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 45, accuracy: 0.01)
        controller.stopHeading()
    }

    func testYawFallbackWhenMapHeadingIsMissing() {
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 45
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)
        controller.startHeadingPreview()
        XCTAssertEqual(controller.headingMode, .followCompass)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 45, accuracy: 0.01)
        controller.stopHeading()
    }

    func testEnablingCustomHeadingAppliesPersistedInitialAndYawDelta() {
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 10
        heading.latestMapHeadingDegrees = 180
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)

        controller.applyPersistedInitial(92)
        controller.startHeadingPreview()
        controller.setCustomHeadingEnabled(true)
        XCTAssertTrue(controller.usesCustomHeading)
        XCTAssertEqual(controller.headingMode, .locked(degrees: 92))
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 92, accuracy: 0.01)

        heading.latestYawDegrees = 190
        heading.onChange?()
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 272, accuracy: 0.01)

        heading.latestYawDegrees = 10
        heading.onChange?()
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 92, accuracy: 0.01)
        controller.stopHeading()
    }

    func testStartDoesNotEnableCustomHeading() {
        let heading = FakePhysicalWalkHeading()
        heading.latestMapHeadingDegrees = 180
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)
        controller.start(latitude: 22.494, longitude: 113.951)
        XCTAssertFalse(controller.usesCustomHeading)
        XCTAssertEqual(controller.headingMode, .followCompass)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 180, accuracy: 0.01)
        controller.stop()
    }

    func testLockHeadingStaysLatentUntilCustomHeadingIsOn() {
        let heading = FakePhysicalWalkHeading()
        heading.latestYawDegrees = 0
        heading.latestMapHeadingDegrees = 180
        let controller = PhysicalWalkController(sensor: FakePhysicalWalkSensor(), heading: heading)
        controller.startHeadingPreview()
        controller.lockHeading(degrees: 90)
        XCTAssertFalse(controller.usesCustomHeading)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 180, accuracy: 0.01)
        XCTAssertEqual(controller.initialHeadingDegrees, 90, accuracy: 0.01)

        controller.setCustomHeadingEnabled(true)
        XCTAssertEqual(controller.activeHeadingDegrees ?? -1, 90, accuracy: 0.01)
        controller.stopHeading()
    }

    func testStaleAuthorizationErrorAfterAllowDoesNotFail() {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var failure = ""
        controller.onFailure = { failure = $0 }

        controller.start(latitude: 22.494, longitude: 113.951)
        sensor.emit(error: Self.motionAuthorizationError)

        XCTAssertTrue(controller.isTracking)
        XCTAssertEqual(failure, "")
        controller.stop()
    }

    private static var motionAuthorizationError: NSError {
        NSError(
            domain: CMErrorDomain,
            code: Int(CMErrorMotionActivityNotAuthorized.rawValue)
        )
    }
}

@MainActor
private final class FakePhysicalWalkSensor: PhysicalWalkSensing {
    var isStepCountingAvailable = true
    var authorization: PhysicalWalkAuthorization = .allowed
    private var handler: ((PhysicalWalkSample?, Error?) -> Void)?

    func authorizationStatus() -> PhysicalWalkAuthorization { authorization }

    func requestAuthorization(_ completion: @escaping (PhysicalWalkAuthorization) -> Void) {
        completion(authorization)
    }

    func start(from date: Date, handler: @escaping (PhysicalWalkSample?, Error?) -> Void) {
        _ = date
        self.handler = handler
    }

    func emit(sample: PhysicalWalkSample? = nil, error: Error? = nil) {
        handler?(sample, error)
    }

    func stop() {
        handler = nil
    }
}

@MainActor
private final class FakePhysicalWalkHeading: PhysicalWalkHeadingSensing {
    var headingAvailable = true
    var latestYawDegrees: Double?
    var latestMapHeadingDegrees: Double?
    var onChange: (() -> Void)?

    func start() {}
    func stop() {
        latestYawDegrees = nil
        latestMapHeadingDegrees = nil
    }
}
