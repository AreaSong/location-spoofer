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
        XCTAssertEqual(
            RoutePlayback.formattedRemaining(meters: 320, speedMetersPerSecond: 1.4),
            "还剩 320 米，约 4 分钟"
        )
    }

    func testCustomSpeedChangesDuration() {
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
        let path = RoutePath.make([start, end])
        let slow = RoutePlayback.tick(path: path, speedMetersPerSecond: 1, elapsed: 50)
        let fast = RoutePlayback.tick(path: path, speedMetersPerSecond: 10, elapsed: 50)
        XCTAssertLessThan(slow.progress, fast.progress)
        XCTAssertFalse(slow.isFinished)
        XCTAssertTrue(fast.isFinished)
    }

    func testOffsetZeroLeavesCoordinateUnchanged() {
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let same = RoutePlayback.offset(pair, radiusMeters: 0)
        XCTAssertEqual(same.wgs84.latitude, pair.wgs84.latitude)
        XCTAssertEqual(same.wgs84.longitude, pair.wgs84.longitude)
    }

    func testReversedPathStartsAtOriginalEnd() {
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
        let reversed = path.reversed()
        XCTAssertEqual(reversed.points.first!.wgs84.latitude, end.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(reversed.points.last!.wgs84.latitude, start.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(reversed.totalMeters, path.totalMeters, accuracy: 0.01)

        let backAtStart = RoutePlayback.tick(path: reversed, mode: .walk, elapsed: 10_000)
        XCTAssertTrue(backAtStart.isFinished)
        XCTAssertEqual(backAtStart.coordinatePair.wgs84.latitude, start.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(backAtStart.coordinatePair.wgs84.longitude, start.wgs84.longitude, accuracy: 0.000_000_1)
    }
}

@MainActor
final class RoutePlaybackControllerTests: XCTestCase {
    func testCanPlayRequiresMinimumDistance() {
        let route = makeRoute()
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
        let route = makeRoute()
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

    func testHandleFinishedLegOnceStops() {
        let route = preparedRoute(repeatMode: .once)
        XCTAssertTrue(route.handleFinishedLeg())
        XCTAssertTrue(route.headingForward)
    }

    func testHandleFinishedLegRoundTripThenStops() {
        let route = preparedRoute(repeatMode: .roundTrip)
        XCTAssertTrue(route.headingForward)
        XCTAssertFalse(route.handleFinishedLeg())
        XCTAssertFalse(route.headingForward)
        XCTAssertTrue(route.handleFinishedLeg())
        XCTAssertFalse(route.headingForward)
    }

    func testHandleFinishedLegLoopKeepsReversing() {
        let route = preparedRoute(repeatMode: .loop)
        XCTAssertFalse(route.handleFinishedLeg())
        XCTAssertFalse(route.headingForward)
        XCTAssertFalse(route.handleFinishedLeg())
        XCTAssertTrue(route.headingForward)
        XCTAssertFalse(route.handleFinishedLeg())
        XCTAssertFalse(route.headingForward)
    }

    func testRequestPlayResetsHeadingAfterRoundTripLeg() {
        let route = preparedRoute(repeatMode: .roundTrip)
        XCTAssertFalse(route.handleFinishedLeg())
        XCTAssertFalse(route.headingForward)
        route.requestPlay()
        XCTAssertTrue(route.headingForward)
    }

    func testLoadRestoresSavedRouteWithoutClearingPins() {
        let saved = sampleSavedRoute(repeatMode: .loop)
        let route = makeRoute()
        route.enter()
        XCTAssertNil(route.start)
        route.load(saved)

        XCTAssertEqual(route.phase, .preparing)
        XCTAssertEqual(route.start!.wgs84.latitude, saved.start.wgs84.latitude)
        XCTAssertEqual(route.end!.wgs84.longitude, saved.end.wgs84.longitude)
        XCTAssertEqual(route.travelMode, .bike)
        XCTAssertEqual(route.repeatMode, .loop)
        XCTAssertEqual(route.speedKilometersPerHour, 18, accuracy: 0.01)
        XCTAssertEqual(route.offsetMeters, 15, accuracy: 0.01)
        XCTAssertEqual(route.path!.points.count, 3)
        XCTAssertEqual(route.vias.count, 1)
        XCTAssertFalse(route.isRouting)
        XCTAssertTrue(route.canPlay)
        XCTAssertTrue(route.headingForward)
        XCTAssertEqual(route.overlayPins.count, 3)
    }

    func testMakeSavedRouteSnapshotsCurrentSettings() {
        let route = makeRoute()
        let saved = sampleSavedRoute(repeatMode: .roundTrip)
        route.load(saved)
        route.applyRepeatMode(.once)
        let snapshot = route.makeSavedRoute(name: "学校")
        XCTAssertEqual(snapshot!.name, "学校")
        XCTAssertEqual(snapshot!.repeatMode, .once)
        XCTAssertEqual(snapshot!.pathPoints!.count, 3)
        XCTAssertEqual(snapshot!.viaPoints.count, 1)
        XCTAssertEqual(snapshot!.start.wgs84.latitude, saved.start.wgs84.latitude)
    }

    func testAddViaAndReverseSwapsStops() {
        let route = makeRoute()
        let saved = sampleSavedRoute(repeatMode: .once)
        route.load(saved)
        XCTAssertEqual(route.start!.wgs84.latitude, saved.start.wgs84.latitude)
        route.reverseDirection()
        XCTAssertEqual(route.start!.wgs84.latitude, saved.end.wgs84.latitude)
        XCTAssertEqual(route.end!.wgs84.latitude, saved.start.wgs84.latitude)
        XCTAssertEqual(route.vias.first!.wgs84.latitude, saved.viaPoints[0].wgs84.latitude)
        XCTAssertEqual(route.path!.points.first!.wgs84.latitude, saved.end.wgs84.latitude)
        XCTAssertTrue(route.headingForward)
    }

    func testPreferencesSurviveNewController() {
        let suite = "RoutePlaybackPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoutePlaybackPreferenceStore(defaults: defaults)
        let route = RoutePlaybackController(preferenceStore: store)
        route.setSpeedKilometersPerHour(7)
        route.setOffsetMeters(25)
        route.applyRepeatMode(.loop)

        let restored = RoutePlaybackController(preferenceStore: store)
        XCTAssertEqual(restored.speedKilometersPerHour, 7, accuracy: 0.01)
        XCTAssertEqual(restored.offsetMeters, 25, accuracy: 0.01)
        XCTAssertEqual(restored.repeatMode, .loop)
    }

    private func makeRoute() -> RoutePlaybackController {
        let suite = "RoutePlaybackControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return RoutePlaybackController(preferenceStore: RoutePlaybackPreferenceStore(defaults: defaults))
    }

    private func preparedRoute(repeatMode: RouteRepeatMode) -> RoutePlaybackController {
        let route = makeRoute()
        route.load(sampleSavedRoute(repeatMode: repeatMode))
        return route
    }

    private func sampleSavedRoute(repeatMode: RouteRepeatMode) -> SavedRoute {
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
        return SavedRoute(
            name: "学校",
            start: start,
            end: end,
            travelMode: .bike,
            speedKilometersPerHour: 18,
            offsetMeters: 15,
            repeatMode: repeatMode,
            viaPoints: [corner],
            pathPoints: [start, corner, end]
        )
    }
}
