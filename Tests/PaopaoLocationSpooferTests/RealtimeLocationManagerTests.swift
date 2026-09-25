import CoreLocation
import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class RealtimeLocationManagerTests: XCTestCase {
    func testFreshCachedLocationReturnsImmediatelyWithoutRequestingAgain() async {
        let driver = FakeRealtimeLocationDriver()
        driver.location = CLLocation(
            coordinate: .init(latitude: 30.42, longitude: 114.25),
            altitude: 0,
            horizontalAccuracy: 12,
            verticalAccuracy: 10,
            timestamp: Date()
        )
        let manager = RealtimeLocationManager(driver: driver, oneShotTimeoutNanoseconds: 1_000_000_000)

        let coordinate = await manager.requestLocation()

        XCTAssertEqual(coordinate?.latitude ?? 0, 30.42, accuracy: 0.000001)
        XCTAssertEqual(driver.requestLocationCallCount, 0)
        XCTAssertEqual(driver.startUpdatingCallCount, 0)
        XCTAssertFalse(manager.isRequesting)
    }

    func testContinuationIsInstalledBeforeOneShotRequest() async {
        let driver = FakeRealtimeLocationDriver()
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)
        driver.onRequestLocation = {
            driver.emit(CLLocation(latitude: 22.54, longitude: 113.94))
        }

        let coordinate = await manager.requestLocation()

        XCTAssertEqual(coordinate?.latitude ?? 0, 22.54, accuracy: 0.000001)
        XCTAssertFalse(manager.isRequesting)
    }

    func testUndeterminedAuthorizationWaitsBeforeRequestingLocation() async {
        let driver = FakeRealtimeLocationDriver()
        driver.authorizationStatus = .notDetermined
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)

        let request = Task { await manager.requestLocation() }
        while !manager.isRequesting { await Task.yield() }

        XCTAssertEqual(driver.requestAuthorizationCallCount, 1)
        XCTAssertEqual(driver.requestLocationCallCount, 0)

        driver.emitAuthorization(.authorizedWhenInUse)
        await Task.yield()
        XCTAssertEqual(driver.requestLocationCallCount, 1)

        driver.emit(CLLocation(latitude: 22.54, longitude: 113.94))
        let coordinate = await request.value
        XCTAssertEqual(coordinate?.latitude ?? 0, 22.54, accuracy: 0.000001)
    }

    func testOverlappingRequestIsRejectedWithoutReplacingFirstContinuation() async {
        let driver = FakeRealtimeLocationDriver()
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)

        let first = Task { await manager.requestLocation() }
        while !manager.isRequesting { await Task.yield() }
        let second = await manager.requestLocation()
        XCTAssertNil(second)

        driver.emit(CLLocation(latitude: 31.23, longitude: 121.47))
        let firstCoordinate = await first.value
        XCTAssertEqual(firstCoordinate?.longitude ?? 0, 121.47, accuracy: 0.000001)
    }

    func testOneShotTimeoutTransitionsToContinuousFallback() async {
        let driver = FakeRealtimeLocationDriver()
        let manager = RealtimeLocationManager(driver: driver, oneShotTimeoutNanoseconds: 5_000_000, fallbackTimeoutNanoseconds: 1_000_000_000)

        let request = Task { await manager.requestLocation() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(driver.startUpdatingCallCount, 1)

        driver.emit(CLLocation(latitude: 39.90, longitude: 116.40))
        let coordinate = await request.value
        XCTAssertEqual(coordinate?.latitude ?? 0, 39.90, accuracy: 0.000001)
        XCTAssertEqual(driver.stopUpdatingCallCount, 1)
    }

    func testInvalidAccuracyCannotCompleteRequest() async {
        let driver = FakeRealtimeLocationDriver()
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)

        let request = Task { await manager.requestLocation() }
        while !manager.isRequesting { await Task.yield() }
        driver.emit(CLLocation(
            coordinate: .init(latitude: 22.54, longitude: 113.94),
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: 10,
            timestamp: Date()
        ))
        await Task.yield()
        XCTAssertTrue(manager.isRequesting)
        XCTAssertNil(manager.location)

        driver.emit(CLLocation(latitude: 31.23, longitude: 121.47))
        let coordinate = await request.value
        XCTAssertEqual(coordinate?.longitude ?? 0, 121.47, accuracy: 0.000001)
    }

    func testDeniedLocationErrorFinishesWithoutStartingFallback() async {
        let driver = FakeRealtimeLocationDriver()
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)

        let request = Task { await manager.requestLocation() }
        while !manager.isRequesting { await Task.yield() }
        driver.emitError(NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue))

        let coordinate = await request.value
        XCTAssertNil(coordinate)
        XCTAssertEqual(driver.startUpdatingCallCount, 0)
        XCTAssertFalse(manager.isRequesting)
    }

    func testCachedSampleAtMaxAgeIsFreshAndJustBeyondIsNot() {
        let manager = RealtimeLocationManager(driver: FakeRealtimeLocationDriver(), timeoutNanoseconds: 1_000_000_000)
        let now = Date()

        XCTAssertTrue(manager.isFreshEnoughForRealtimeRequest(sample(age: -20, now: now), now: now))
        XCTAssertFalse(manager.isFreshEnoughForRealtimeRequest(sample(age: -20.001, now: now), now: now))
        XCTAssertFalse(manager.isFreshEnoughForRealtimeRequest(sample(age: -20, now: now, horizontalAccuracy: -1), now: now))
    }

    func testStaleCachedLocationFallsThroughToOneShot() async {
        let driver = FakeRealtimeLocationDriver()
        driver.location = sample(age: -21, now: Date())
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)

        let request = Task { await manager.requestLocation() }
        while !manager.isRequesting { await Task.yield() }

        XCTAssertEqual(driver.requestLocationCallCount, 1)
        driver.emit(CLLocation(latitude: 22.54, longitude: 113.94))
        let coordinate = await request.value
        XCTAssertEqual(coordinate?.latitude ?? 0, 22.54, accuracy: 0.000001)
    }

    func testOldTimestampCannotCompleteNewRequest() async {
        let driver = FakeRealtimeLocationDriver()
        let manager = RealtimeLocationManager(driver: driver, timeoutNanoseconds: 1_000_000_000)

        let request = Task { await manager.requestLocation() }
        while !manager.isRequesting { await Task.yield() }
        driver.emit(CLLocation(
            coordinate: .init(latitude: 1, longitude: 2),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10,
            timestamp: Date(timeIntervalSinceNow: -60)
        ))
        await Task.yield()
        XCTAssertTrue(manager.isRequesting)

        driver.emit(CLLocation(latitude: 22.54, longitude: 113.94))
        let coordinate = await request.value
        XCTAssertEqual(coordinate?.latitude ?? 0, 22.54, accuracy: 0.000001)
    }
}

@MainActor
private func sample(age: TimeInterval, now: Date, horizontalAccuracy: CLLocationAccuracy = 12) -> CLLocation {
    CLLocation(
        coordinate: .init(latitude: 30.42, longitude: 114.25),
        altitude: 0,
        horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: 10,
        timestamp: now.addingTimeInterval(age)
    )
}

@MainActor
private final class FakeRealtimeLocationDriver: RealtimeLocationDriving {
    var location: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    weak var delegate: CLLocationManagerDelegate?
    var onRequestLocation: (() -> Void)?
    private(set) var requestAuthorizationCallCount = 0
    private(set) var requestLocationCallCount = 0
    private(set) var startUpdatingCallCount = 0
    private(set) var stopUpdatingCallCount = 0

    func requestWhenInUseAuthorization() {
        requestAuthorizationCallCount += 1
    }

    func requestLocation() {
        requestLocationCallCount += 1
        onRequestLocation?()
    }

    func startUpdatingLocation() {
        startUpdatingCallCount += 1
    }

    func stopUpdatingLocation() {
        stopUpdatingCallCount += 1
    }

    func emitAuthorization(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        delegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
    }

    func emit(_ location: CLLocation) {
        delegate?.locationManager?(CLLocationManager(), didUpdateLocations: [location])
    }

    func emitError(_ error: Error) {
        delegate?.locationManager?(CLLocationManager(), didFailWithError: error)
    }
}
