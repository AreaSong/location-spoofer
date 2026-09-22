import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class RouteDirectionsTests: XCTestCase {
    func testFailedRouteFallsBackToStraightLine() async {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.952,
            mapCoordinateSystem: .wgs84
        )
        let points = await RouteDirections.waypoints(
            from: start,
            to: end,
            mode: .walk,
            provider: StubRouteDirections(result: nil)
        )
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].wgs84.latitude, start.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(points[1].wgs84.longitude, end.wgs84.longitude, accuracy: 0.000_000_1)
    }

    func testWaypointsConcatenateLegsAndDropSharedAnchor() async {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let via = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.952,
            mapCoordinateSystem: .wgs84
        )
        let provider = StubRouteDirections { from, to in
            let mid = CoordinateConverter.coordinatePair(
                lat: (from.wgs84.latitude + to.wgs84.latitude) / 2,
                lon: (from.wgs84.longitude + to.wgs84.longitude) / 2,
                mapCoordinateSystem: .wgs84
            )
            return [from, mid, to]
        }

        let points = await RouteDirections.waypoints(
            along: [start, via, end],
            mode: .bike,
            provider: provider
        )
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points[0].wgs84.latitude, start.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(points[2].wgs84.latitude, via.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(points[4].wgs84.longitude, end.wgs84.longitude, accuracy: 0.000_000_1)
    }
}

private struct StubRouteDirections: RouteDirectionsProviding {
    var result: [CoordinatePair]?
    var factory: ((CoordinatePair, CoordinatePair) -> [CoordinatePair]?)?

    init(result: [CoordinatePair]?) {
        self.result = result
    }

    init(factory: @escaping (CoordinatePair, CoordinatePair) -> [CoordinatePair]?) {
        self.factory = factory
    }

    @MainActor
    func routePoints(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode
    ) async -> [CoordinatePair]? {
        factory?(start, end) ?? result
    }
}
