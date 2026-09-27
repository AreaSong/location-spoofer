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
        XCTAssertEqual(store.lastFailureMessage, "")

        store.setEnabled(true)
        XCTAssertTrue(PhysicalWalkStore(defaults: defaults).isEnabled)

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

    func testTenMeterWalkWritesTheDisplacedCoordinate() async throws {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latest = PhysicalWalkHeading(degrees: 0, accuracyDegrees: 5)
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

    func testUnreliableHeadingDoesNotWrite() async {
        let sensor = FakePhysicalWalkSensor()
        let heading = FakePhysicalWalkHeading()
        heading.latest = PhysicalWalkHeading(degrees: 90, accuracyDegrees: -1)
        let controller = PhysicalWalkController(sensor: sensor, heading: heading)
        var wrote = false
        controller.applyCoordinate = { _ in
            wrote = true
            return true
        }
        controller.start(latitude: 22.494, longitude: 113.951)
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0))
        await controller.ingest(sample: PhysicalWalkSample(distanceMeters: 10, steps: 12))

        XCTAssertFalse(wrote)
        XCTAssertEqual(controller.status, .waitingForHeading)
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
    var latest: PhysicalWalkHeading?

    func start() {}
    func stop() { latest = nil }
}
