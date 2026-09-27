import XCTest
@testable import PaopaoLocationSpoofer

final class PhysicalWalkDisplacementTests: XCTestCase {
    private let originLatitude = 22.494
    private let originLongitude = 113.951

    func testZeroDistanceLeavesCoordinateUnchanged() {
        let shifted = PhysicalWalkDisplacement.offsetWGS84(
            latitude: originLatitude,
            longitude: originLongitude,
            distanceMeters: 0,
            headingDegrees: 90
        )

        XCTAssertEqual(shifted.latitude, originLatitude)
        XCTAssertEqual(shifted.longitude, originLongitude)
    }

    func testNorthOffsetMatchesRequestedDistance() {
        let shifted = PhysicalWalkDisplacement.offsetWGS84(
            latitude: originLatitude,
            longitude: originLongitude,
            distanceMeters: 50,
            headingDegrees: 0
        )
        let distance = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: shifted.latitude,
            lon2: shifted.longitude
        )

        XCTAssertEqual(distance, 50, accuracy: 0.5)
        XCTAssertEqual(shifted.longitude, originLongitude, accuracy: 0.000_000_1)
        XCTAssertGreaterThan(shifted.latitude, originLatitude)
    }

    func testEastOffsetIncreasesLongitude() {
        let shifted = PhysicalWalkDisplacement.offsetWGS84(
            latitude: originLatitude,
            longitude: originLongitude,
            distanceMeters: 40,
            headingDegrees: 90
        )
        let distance = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: shifted.latitude,
            lon2: shifted.longitude
        )

        XCTAssertEqual(distance, 40, accuracy: 0.5)
        XCTAssertEqual(shifted.latitude, originLatitude, accuracy: 0.000_01)
        XCTAssertGreaterThan(shifted.longitude, originLongitude)
    }

    func testEngineIgnoresTheFirstSampleThenAccumulatesTwoLegs() {
        var engine = PhysicalWalkEngine(latitude: originLatitude, longitude: originLongitude)
        let heading = PhysicalWalkHeading(degrees: 0, accuracyDegrees: 5)

        XCTAssertEqual(
            engine.apply(sample: PhysicalWalkSample(distanceMeters: 0, steps: 0), heading: heading),
            .unchanged
        )

        let north = engine.apply(
            sample: PhysicalWalkSample(distanceMeters: 10, steps: 12),
            heading: heading
        )
        XCTAssertEqual(north, .moved(deltaMeters: 10))
        let afterNorth = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: engine.latitude,
            lon2: engine.longitude
        )
        XCTAssertEqual(afterNorth, 10, accuracy: 0.5)

        let eastHeading = PhysicalWalkHeading(degrees: 90, accuracyDegrees: 4)
        let east = engine.apply(
            sample: PhysicalWalkSample(distanceMeters: 18, steps: 22),
            heading: eastHeading
        )
        XCTAssertEqual(east, .moved(deltaMeters: 8))
        XCTAssertEqual(engine.movedMeters, 18, accuracy: 0.001)
        let fromOrigin = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: engine.latitude,
            lon2: engine.longitude
        )
        XCTAssertEqual(fromOrigin, hypot(10, 8), accuracy: 0.6)
    }

    func testUnreliableHeadingConsumesDistanceWithoutMoving() {
        var engine = PhysicalWalkEngine(latitude: originLatitude, longitude: originLongitude)
        _ = engine.apply(
            sample: PhysicalWalkSample(distanceMeters: 0, steps: 0),
            heading: PhysicalWalkHeading(degrees: 0, accuracyDegrees: 5)
        )

        let skipped = engine.apply(
            sample: PhysicalWalkSample(distanceMeters: 12, steps: 16),
            heading: PhysicalWalkHeading(degrees: 90, accuracyDegrees: -1)
        )
        XCTAssertEqual(skipped, .waitingForHeading)
        XCTAssertEqual(engine.latitude, originLatitude)
        XCTAssertEqual(engine.longitude, originLongitude)

        let later = engine.apply(
            sample: PhysicalWalkSample(distanceMeters: 12.2, steps: 17),
            heading: PhysicalWalkHeading(degrees: 0, accuracyDegrees: 8)
        )
        XCTAssertEqual(later, .moved(deltaMeters: 0.2), accuracy: 0.000_1)
        XCTAssertEqual(engine.movedMeters, 0.2, accuracy: 0.000_1)
    }

    func testStepFallbackUsesDefaultStrideWhenDistanceIsMissing() {
        var engine = PhysicalWalkEngine(latitude: originLatitude, longitude: originLongitude)
        let heading = PhysicalWalkHeading(degrees: 0, accuracyDegrees: 5)
        _ = engine.apply(sample: PhysicalWalkSample(steps: 0), heading: heading)

        let moved = engine.apply(sample: PhysicalWalkSample(steps: 10), heading: heading)
        XCTAssertEqual(moved, .moved(deltaMeters: 7.4), accuracy: 0.000_1)
        let distance = CoordinateConverter.distance(
            lat1: originLatitude,
            lon1: originLongitude,
            lat2: engine.latitude,
            lon2: engine.longitude
        )
        XCTAssertEqual(distance, 7.4, accuracy: 0.5)
    }

    func testSessionTrackingRequiresActiveSpoofAndNoRouteMotion() {
        XCTAssertTrue(
            PhysicalWalkSession.shouldTrack(
                isEnabled: true,
                spoofActive: true,
                routePlaying: false,
                routeWaiting: false,
                preview: false,
                useBlocked: false
            )
        )
        XCTAssertFalse(
            PhysicalWalkSession.shouldTrack(
                isEnabled: true,
                spoofActive: true,
                routePlaying: true,
                routeWaiting: false,
                preview: false,
                useBlocked: false
            )
        )
        XCTAssertFalse(
            PhysicalWalkSession.shouldTrack(
                isEnabled: true,
                spoofActive: true,
                routePlaying: false,
                routeWaiting: true,
                preview: false,
                useBlocked: false
            )
        )
        XCTAssertTrue(PhysicalWalkSession.shouldPauseRoute(isEnabled: true, routePlaying: true))
        XCTAssertTrue(PhysicalWalkSession.shouldDisableForRoutePlayback(routePlaying: false, routeWaiting: true))
    }

    func testSensorPolicyIgnoresAuthorizationErrorsUntilTheUserResponds() {
        XCTAssertEqual(
            PhysicalWalkSensorPolicy.action(forAuthorization: .notDetermined, isAuthorizationError: true),
            .ignore
        )
        XCTAssertEqual(
            PhysicalWalkSensorPolicy.action(forAuthorization: .allowed, isAuthorizationError: true),
            .ignore
        )
        XCTAssertEqual(
            PhysicalWalkSensorPolicy.action(forAuthorization: .denied, isAuthorizationError: true),
            .fail(PhysicalWalkSensorPolicy.permissionDeniedMessage)
        )
        XCTAssertEqual(
            PhysicalWalkSensorPolicy.action(forAuthorization: .allowed, isAuthorizationError: false),
            .fail(PhysicalWalkSensorPolicy.sensorUnavailableMessage)
        )
    }

    func testAvailabilityMessageAsksForMotionPermissionOnlyAfterDenial() {
        XCTAssertNil(
            PhysicalWalkSensorPolicy.availabilityMessage(
                stepCountingAvailable: true,
                authorization: .notDetermined,
                headingAvailable: true
            )
        )
        XCTAssertEqual(
            PhysicalWalkSensorPolicy.availabilityMessage(
                stepCountingAvailable: true,
                authorization: .denied,
                headingAvailable: true
            ),
            PhysicalWalkSensorPolicy.permissionDeniedMessage
        )
    }
}

private func XCTAssertEqual(
    _ expression: PhysicalWalkApplyResult,
    _ expected: PhysicalWalkApplyResult,
    accuracy: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (expression, expected) {
    case let (.moved(lhs), .moved(rhs)):
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, file: file, line: line)
    default:
        XCTAssertEqual(expression, expected, file: file, line: line)
    }
}
