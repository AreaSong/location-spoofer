import CoreLocation
import XCTest
@testable import PaopaoLocationSpoofer

final class SmoothCruiseTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)

    func testDurationCopyUsesOneDecimalPlace() {
        XCTAssertEqual(SmoothCruisePolicy.durationSeconds, 1.4, accuracy: 0.000_000_1)
        XCTAssertEqual(SmoothCruisePolicy.durationSecondsText, "1.4")
    }

    func testDisabledOrInactiveOrRouteActivationDoesNotInterpolate() {
        let destination = coordinate(northOf: origin, atLeast: 80)

        XCTAssertFalse(
            SmoothCruisePolicy.shouldInterpolate(
                enabled: false,
                spoofActive: true,
                isRouteActivation: false,
                from: origin,
                to: destination
            )
        )
        XCTAssertFalse(
            SmoothCruisePolicy.shouldInterpolate(
                enabled: true,
                spoofActive: false,
                isRouteActivation: false,
                from: origin,
                to: destination
            )
        )
        XCTAssertFalse(
            SmoothCruisePolicy.shouldInterpolate(
                enabled: true,
                spoofActive: true,
                isRouteActivation: true,
                from: origin,
                to: destination
            )
        )
        XCTAssertFalse(
            SmoothCruisePolicy.shouldInterpolate(
                enabled: true,
                spoofActive: true,
                isRouteActivation: false,
                from: nil,
                to: destination
            )
        )
    }

    func testDistanceWindowGatesInterpolation() {
        let inside = coordinate(northOf: origin, atLeast: 80)
        let tooClose = coordinate(northOf: origin, atMost: 20)
        let tooFar = coordinate(northOf: origin, atLeast: 600_000)

        XCTAssertGreaterThan(distance(from: origin, to: inside), SmoothCruisePolicy.minimumDistanceMeters)
        XCTAssertLessThan(distance(from: origin, to: inside), SmoothCruisePolicy.maximumDistanceMeters)
        XCTAssertLessThan(distance(from: origin, to: tooClose), SmoothCruisePolicy.minimumDistanceMeters)
        XCTAssertGreaterThan(distance(from: origin, to: tooFar), SmoothCruisePolicy.maximumDistanceMeters)

        XCTAssertTrue(shouldInterpolate(to: inside))
        XCTAssertFalse(shouldInterpolate(to: tooClose))
        XCTAssertFalse(shouldInterpolate(to: tooFar))
        XCTAssertFalse(shouldInterpolate(to: origin))
    }

    func testInclusiveDistanceBoundariesInterpolate() {
        let minimum = coordinate(northOf: origin, atLeast: SmoothCruisePolicy.minimumDistanceMeters)
        let maximum = coordinate(northOf: origin, atMost: SmoothCruisePolicy.maximumDistanceMeters)

        XCTAssertGreaterThanOrEqual(distance(from: origin, to: minimum), SmoothCruisePolicy.minimumDistanceMeters)
        XCTAssertLessThanOrEqual(distance(from: origin, to: maximum), SmoothCruisePolicy.maximumDistanceMeters)
        XCTAssertTrue(shouldInterpolate(to: minimum))
        XCTAssertTrue(shouldInterpolate(to: maximum))
    }

    private func shouldInterpolate(to destination: CLLocationCoordinate2D) -> Bool {
        SmoothCruisePolicy.shouldInterpolate(
            enabled: true,
            spoofActive: true,
            isRouteActivation: false,
            from: origin,
            to: destination
        )
    }

    private func coordinate(
        northOf origin: CLLocationCoordinate2D,
        atLeast meters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        refine(northOf: origin, meters: meters, chooseUpper: true)
    }

    private func coordinate(
        northOf origin: CLLocationCoordinate2D,
        atMost meters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        refine(northOf: origin, meters: meters, chooseUpper: false)
    }

    private func refine(
        northOf origin: CLLocationCoordinate2D,
        meters: CLLocationDistance,
        chooseUpper: Bool
    ) -> CLLocationCoordinate2D {
        let start = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var low = origin.latitude
        var high = origin.latitude + max(meters / 100_000.0, 0.01)
        while start.distance(from: CLLocation(latitude: high, longitude: origin.longitude)) < meters {
            high += high - origin.latitude
        }
        for _ in 0..<48 {
            let mid = (low + high) / 2
            if start.distance(from: CLLocation(latitude: mid, longitude: origin.longitude)) < meters {
                low = mid
            } else {
                high = mid
            }
        }
        let latitude = chooseUpper ? high : low
        return CLLocationCoordinate2D(latitude: latitude, longitude: origin.longitude)
    }

    private func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }
}
