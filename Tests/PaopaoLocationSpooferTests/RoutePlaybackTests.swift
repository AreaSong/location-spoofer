import XCTest
@testable import PaopaoLocationSpoofer

final class RoutePlaybackTests: XCTestCase {
    func testDistanceUsesWGS84() {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let meters = RoutePlayback.distanceMeters(from: start, to: end)
        XCTAssertEqual(meters, 111.2, accuracy: 2)
    }

    func testInterpolateEndsMatchProgress() {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.496,
            lon: 113.953,
            mapCoordinateSystem: .wgs84
        )

        let atStart = RoutePlayback.interpolate(from: start, to: end, progress: 0)
        XCTAssertEqual(atStart.wgs84.latitude, start.wgs84.latitude, accuracy: 0.000_000_01)
        XCTAssertEqual(atStart.wgs84.longitude, start.wgs84.longitude, accuracy: 0.000_000_01)

        let atEnd = RoutePlayback.interpolate(from: start, to: end, progress: 1)
        XCTAssertEqual(atEnd.wgs84.latitude, end.wgs84.latitude, accuracy: 0.000_000_01)
        XCTAssertEqual(atEnd.wgs84.longitude, end.wgs84.longitude, accuracy: 0.000_000_01)

        let mid = RoutePlayback.interpolate(from: start, to: end, progress: 0.5)
        XCTAssertEqual(mid.wgs84.latitude, 22.495, accuracy: 0.000_000_01)
        XCTAssertEqual(mid.wgs84.longitude, 113.952, accuracy: 0.000_000_01)
    }

    func testTickFollowsPolylineDistance() {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let corner = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.952,
            mapCoordinateSystem: .wgs84
        )
        let path = RoutePath.make([start, corner, end])
        XCTAssertEqual(path.points.count, 3)
        XCTAssertGreaterThan(path.totalMeters, 200)

        let midpoint = RoutePlayback.interpolate(path: path, progress: 0.5)
        XCTAssertEqual(midpoint.wgs84.latitude, corner.wgs84.latitude, accuracy: 0.000_05)
        XCTAssertEqual(midpoint.wgs84.longitude, corner.wgs84.longitude, accuracy: 0.000_05)

        let last = RoutePlayback.tick(path: path, mode: .walk, elapsed: 10_000)
        XCTAssertTrue(last.isFinished)
        XCTAssertEqual(last.coordinatePair.wgs84.latitude, end.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(last.coordinatePair.wgs84.longitude, end.wgs84.longitude, accuracy: 0.000_000_1)
    }

    func testTickFinishesAfterDuration() {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let distance = RoutePlayback.distanceMeters(from: start, to: end)
        let duration = distance / RouteTravelMode.walk.metersPerSecond

        let first = RoutePlayback.tick(from: start, to: end, mode: .walk, elapsed: 0)
        XCTAssertFalse(first.isFinished)
        XCTAssertEqual(first.progress, 0, accuracy: 0.000_1)
        XCTAssertEqual(first.coordinatePair.wgs84.latitude, start.wgs84.latitude, accuracy: 0.000_000_01)

        let last = RoutePlayback.tick(from: start, to: end, mode: .walk, elapsed: duration + 1)
        XCTAssertTrue(last.isFinished)
        XCTAssertEqual(last.progress, 1, accuracy: 0.000_1)
        XCTAssertEqual(last.coordinatePair.wgs84.latitude, end.wgs84.latitude, accuracy: 0.000_000_01)
        XCTAssertEqual(last.remainingMeters, 0, accuracy: 0.01)
    }

    func testFormattedCopy() {
        XCTAssertEqual(RoutePlayback.formattedDistance(500), "500 米")
        XCTAssertEqual(RoutePlayback.formattedDistance(1_500), "1.5 公里")
        XCTAssertEqual(
            RoutePlayback.formattedDuration(meters: 100, mode: .walk),
            "约 2 分钟"
        )
    }
}

@MainActor
final class RoutePlaybackControllerTests: XCTestCase {
    func testCanPlayRequiresMinimumDistance() {
        let route = RoutePlaybackController()
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        route.enter(start: start)
        XCTAssertFalse(route.canPlay)

        let tooClose = CoordinateConverter.coordinatePair(
            lat: 22.49405,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        route.setEnd(tooClose)
        XCTAssertLessThan(RoutePlayback.distanceMeters(from: start, to: tooClose), 10)
        XCTAssertFalse(route.canPlay)

        let farEnough = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        route.setEnd(farEnough)
        XCTAssertTrue(route.canPlay)
        XCTAssertEqual(route.overlayCoordinates.count, 2)
    }

    func testRequestPlayWaitsForActivation() {
        let route = RoutePlaybackController()
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        route.enter(start: start)
        route.setEnd(end)
        route.requestPlay()

        XCTAssertTrue(route.waitingForActivation)
        XCTAssertEqual(route.phase, .preparing)
        XCTAssertEqual(route.progress, 0)
    }
}
