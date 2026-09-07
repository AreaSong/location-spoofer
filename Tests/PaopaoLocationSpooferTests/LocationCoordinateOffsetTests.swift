import XCTest
@testable import PaopaoLocationSpoofer

final class LocationCoordinateOffsetTests: XCTestCase {
    func testZeroRadiusLeavesCoordinateUnchanged() {
        let shifted = LocationCoordinateOffset.offsetWGS84(
            latitude: 22.494,
            longitude: 113.951,
            radiusMeters: 0
        )

        XCTAssertEqual(shifted.latitude, 22.494)
        XCTAssertEqual(shifted.longitude, 113.951)
    }

    func testZeroFractionLeavesCoordinateUnchanged() {
        let shifted = LocationCoordinateOffset.offsetWGS84(
            latitude: 22.494,
            longitude: 113.951,
            radiusMeters: 80,
            angleRadians: .pi / 3,
            radiusFraction: 0
        )

        XCTAssertEqual(shifted.latitude, 22.494)
        XCTAssertEqual(shifted.longitude, 113.951)
    }

    func testNorthOffsetMatchesRequestedDistance() {
        let originLatitude = 22.494
        let originLongitude = 113.951
        let shifted = LocationCoordinateOffset.offsetWGS84(
            latitude: originLatitude,
            longitude: originLongitude,
            radiusMeters: 50,
            angleRadians: 0,
            radiusFraction: 1
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

    func testRandomOffsetsStayInsideTheRadius() {
        let originLatitude = 39.9042
        let originLongitude = 116.4074
        for _ in 0..<100 {
            let shifted = LocationCoordinateOffset.offsetWGS84(
                latitude: originLatitude,
                longitude: originLongitude,
                radiusMeters: 80
            )
            let distance = CoordinateConverter.distance(
                lat1: originLatitude,
                lon1: originLongitude,
                lat2: shifted.latitude,
                lon2: shifted.longitude
            )
            XCTAssertLessThanOrEqual(distance, 81)
        }
    }
}
