import XCTest
@testable import PaopaoLocationSpoofer

final class RoutePathSimplifierTests: XCTestCase {
    func testCollinearReturnBeyondEndpointKeepsTurningPoint() {
        let points = returningPath(endLongitude: 0.005)
        let simplified = RoutePathSimplifier.simplify(points)
        XCTAssertEqual(points.count, 501)
        XCTAssertEqual(simplified.first, points.first)
        XCTAssertEqual(simplified.last, points.last)
        XCTAssertEqual(simplified.map(\.wgs84.longitude).max() ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertGreaterThan(RoutePath.make(simplified).totalMeters, 3_800)
    }

    func testClosedReturnKeepsTurningPointAndEndpointOrder() {
        let points = returningPath(endLongitude: 0)
        let simplified = RoutePathSimplifier.simplify(points)
        XCTAssertEqual(simplified, [points[0], points[250], points[500]])
        XCTAssertGreaterThan(RoutePath.make(simplified).totalMeters, 4_400)
    }

    func testDuplicatePointsAndZeroLengthSegmentsAreSafe() {
        let points = Array(repeating: pair(0), count: 200)
            + Array(repeating: pair(0.02), count: 200)
            + Array(repeating: pair(0), count: 200)
        XCTAssertEqual(RoutePathSimplifier.simplify(points), [pair(0), pair(0.02), pair(0)])
        XCTAssertEqual(RoutePathSimplifier.simplify(Array(repeating: pair(0), count: 501)), [pair(0), pair(0)])
    }

    func testStraightLineStillSimplifiesToEndpoints() {
        let points = (0...500).map { pair(Double($0) * 0.00004) }
        XCTAssertEqual(RoutePathSimplifier.simplify(points), [points[0], points[500]])
    }

    func testCurveRetainsOrderedSourcePointsAndStaysWithinLimit() throws {
        let points = (0...1_000).map { index in
            CoordinateConverter.coordinatePair(
                lat: Double(index) * 0.00001,
                lon: sin(Double(index) / 40) * 0.01,
                mapCoordinateSystem: .wgs84
            )
        }
        let simplified = RoutePathSimplifier.simplify(points)
        XCTAssertEqual(simplified.first, points.first)
        XCTAssertEqual(simplified.last, points.last)
        XCTAssertGreaterThan(simplified.count, 10)
        XCTAssertLessThanOrEqual(simplified.count, 400)
        var previousIndex = -1
        for point in simplified {
            let index = try XCTUnwrap(points.firstIndex(of: point))
            XCTAssertGreaterThan(index, previousIndex)
            previousIndex = index
        }
        XCTAssertEqual(RoutePath.make(simplified).totalMeters, RoutePath.make(points).totalMeters, accuracy: 500)
    }

    func testSaveReloadAndExportPreserveCollinearReturn() throws {
        let suite = "ReturningRoute.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let points = returningPath(endLongitude: 0.005)
        let route = SavedRoute(name: "合成折返", start: points[0], end: points[500], travelMode: .walk,
                               speedKilometersPerHour: 5, offsetMeters: 0, repeatMode: .once, pathPoints: points)
        let store = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let saved = try store.save(route)
        let reloaded = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let exported = try XCTUnwrap(RouteTransfer.decode(reloaded.exportTransferred()).first)
        for candidate in [saved, try XCTUnwrap(reloaded.routes.first), exported] {
            let path = try XCTUnwrap(candidate.pathPoints)
            XCTAssertEqual(path, [points[0], points[250], points[500]])
            XCTAssertGreaterThan(candidate.distanceMeters, 3_800)
        }
    }

    private func returningPath(endLongitude: Double) -> [CoordinatePair] {
        (0...500).map { index in
            let longitude = index <= 250 ? Double(index) / 250 * 0.02
                : 0.02 + Double(index - 250) / 250 * (endLongitude - 0.02)
            return pair(longitude)
        }
    }

    private func pair(_ longitude: Double) -> CoordinatePair {
        CoordinateConverter.coordinatePair(lat: 0, lon: longitude, mapCoordinateSystem: .wgs84)
    }
}
