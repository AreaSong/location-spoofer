import Combine
import XCTest
@testable import PaopaoLocationSpoofer

private final class ActivationGate: @unchecked Sendable {
    var resume: (() -> Void)?
}

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

    func testWriteGateRequiresDistanceOrElapsedTime() {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let nearby = CoordinateConverter.coordinatePair(
            lat: 22.49402,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let far = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        XCTAssertLessThan(RoutePlayback.distanceMeters(from: start, to: nearby), RouteWriteGate.minimumDistanceMeters)
        XCTAssertGreaterThan(RoutePlayback.distanceMeters(from: start, to: far), RouteWriteGate.minimumDistanceMeters)

        var gate = RouteWriteGate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(gate.shouldWrite(start, at: t0, force: false))
        gate.markWritten(start, at: t0)

        XCTAssertFalse(gate.shouldWrite(nearby, at: t0.addingTimeInterval(1), force: false))
        XCTAssertTrue(gate.shouldWrite(far, at: t0.addingTimeInterval(1), force: false))
        XCTAssertTrue(gate.shouldWrite(nearby, at: t0.addingTimeInterval(RouteWriteGate.minimumInterval), force: false))
        XCTAssertTrue(gate.shouldWrite(nearby, at: t0.addingTimeInterval(1), force: true))

        gate.reset()
        XCTAssertTrue(gate.shouldWrite(nearby, at: t0.addingTimeInterval(1), force: false))
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

    @MainActor
    func testExitBeforeActivationStartsDoesNotWrite() async {
        let route = preparedRoute(repeatMode: .once)
        var writes = 0
        route.applyCoordinate = { _ in
            writes += 1
            return true
        }
        route.requestPlay()
        route.beginActivation()
        let pending = route.exit()

        await Task.yield()
        await pending?.value
        XCTAssertNil(pending)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(route.phase, .inactive)
        XCTAssertFalse(route.waitingForActivation)
    }

    @MainActor
    func testExitDuringActivationDoesNotStartPlayback() async {
        let route = preparedRoute(repeatMode: .once)
        let started = expectation(description: "write started")
        let gate = ActivationGate()
        var writes = 0
        route.applyCoordinate = { _ in
            writes += 1
            started.fulfill()
            await withCheckedContinuation { continuation in
                gate.resume = { continuation.resume() }
            }
            return true
        }
        route.requestPlay()
        route.beginActivation()
        await fulfillment(of: [started], timeout: 2)
        let pending = route.exit()
        gate.resume?()

        await pending?.value
        XCTAssertNotNil(pending)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(route.phase, .inactive)
        XCTAssertFalse(route.waitingForActivation)
    }

    func testPlaybackTicksDoNotPublishRouteStructure() async {
        let route = preparedRoute(repeatMode: .once)
        route.tickIntervalNanoseconds = 20_000_000
        route.applyCoordinate = { _ in true }
        var structuralChanges = 0
        let structuralToken = route.objectWillChange.sink { structuralChanges += 1 }
        route.requestPlay()
        route.noteActivated()
        let baseline = structuralChanges
        let progressed = expectation(description: "playback clock advances")
        var fulfilled = false
        let progressToken = route.clock.$progress.sink { value in
            guard value > 0, !fulfilled else { return }
            fulfilled = true
            progressed.fulfill()
        }
        await fulfillment(of: [progressed], timeout: 2)
        XCTAssertEqual(structuralChanges, baseline)
        XCTAssertEqual(route.clock.progress, route.progress)
        XCTAssertEqual(route.clock.current, route.current)
        route.pause()
        structuralToken.cancel()
        progressToken.cancel()
    }

    func testSwitchButtonUsesLastWrittenCoordinate() {
        let written = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let nearby = CoordinateConverter.coordinatePair(
            lat: 22.49405,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        XCTAssertFalse(
            SpoofSelectionSwitch.needsSwitch(
                isActive: true,
                writtenLatitude: written.wgs84.latitude,
                writtenLongitude: written.wgs84.longitude,
                selection: nearby
            )
        )

        let elsewhere = CoordinateConverter.coordinatePair(
            lat: 22.5,
            lon: 113.96,
            mapCoordinateSystem: .wgs84
        )
        XCTAssertTrue(
            SpoofSelectionSwitch.needsSwitch(
                isActive: true,
                writtenLatitude: written.wgs84.latitude,
                writtenLongitude: written.wgs84.longitude,
                selection: elsewhere
            )
        )
        XCTAssertFalse(
            SpoofSelectionSwitch.needsSwitch(
                isActive: false,
                writtenLatitude: written.wgs84.latitude,
                writtenLongitude: written.wgs84.longitude,
                selection: elsewhere
            )
        )
        XCTAssertFalse(
            SpoofSelectionSwitch.needsSwitch(
                isActive: true,
                writtenLatitude: nil,
                writtenLongitude: nil,
                selection: elsewhere
            )
        )
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

    func testStaleWriteCannotPauseOrMoveTheReplacementRoute() async {
        let route = preparedRoute(repeatMode: .once)
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 1_000_000
        let entered = expectation(description: "旧写入挂起")
        let hold = PlaybackWriteHold()
        route.applyCoordinate = { _ in
            await hold.wait(entered)
        }
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)

        let start = CoordinateConverter.coordinatePair(lat: 31.23, lon: 121.47, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 31.24, lon: 121.47, mapCoordinateSystem: .wgs84)
        route.load(SavedRoute(
            name: "新路线",
            start: start,
            end: end,
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            pathPoints: [start, end]
        ))
        route.ignoresWriteGate = true
        let replacementEntered = expectation(description: "新写入挂起")
        let replacementHold = PlaybackWriteHold()
        route.applyCoordinate = { _ in
            await replacementHold.wait(replacementEntered)
        }
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [replacementEntered], timeout: 2)

        hold.resume(returning: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(route.phase, .playing)
        XCTAssertNotEqual(route.statusMessage, route.pushFailureMessage)
        XCTAssertEqual(route.current?.wgs84.latitude ?? 0, start.wgs84.latitude, accuracy: 0.000_1)
        replacementHold.resume(returning: true)
        route.pause()
    }

    func testStaleFailureCannotPauseTheReplacementRoute() async {
        let route = preparedRoute(repeatMode: .once)
        route.ignoresWriteGate = true
        let entered = expectation(description: "失败写入挂起")
        let hold = PlaybackWriteHold()
        route.applyCoordinate = { _ in
            await hold.wait(entered)
        }
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)

        route.load(sampleSavedRoute(repeatMode: .loop))
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 60_000_000_000
        route.applyCoordinate = { _ in true }
        route.requestPlay()
        route.noteActivated()

        hold.resume(returning: false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(route.phase, .playing)
        XCTAssertNotEqual(route.statusMessage, route.pushFailureMessage)
        route.pause()
    }

    func testStaleFinishedWriteCannotCompleteTheReplacementRoute() async {
        let route = preparedRoute(repeatMode: .once)
        let start = CoordinateConverter.coordinatePair(lat: 22.494, lon: 113.951, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.49415, lon: 113.951, mapCoordinateSystem: .wgs84)
        route.load(SavedRoute(
            name: "短路线",
            start: start,
            end: end,
            travelMode: .bike,
            speedKilometersPerHour: 40,
            offsetMeters: 0,
            repeatMode: .once,
            pathPoints: [start, end]
        ))
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 10_000_000
        route.setSpeedKilometersPerHour(40)
        let entered = expectation(description: "终点写入挂起")
        let hold = PlaybackWriteHold()
        route.applyCoordinate = { _ in
            guard route.progress >= 1 else { return true }
            return await hold.wait(entered)
        }
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 3)

        let nextStart = CoordinateConverter.coordinatePair(lat: 31.23, lon: 121.47, mapCoordinateSystem: .wgs84)
        let nextEnd = CoordinateConverter.coordinatePair(lat: 31.25, lon: 121.47, mapCoordinateSystem: .wgs84)
        route.load(SavedRoute(
            name: "下一条",
            start: nextStart,
            end: nextEnd,
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            pathPoints: [nextStart, nextEnd]
        ))
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 60_000_000_000
        route.applyCoordinate = { _ in true }
        route.requestPlay()
        route.noteActivated()

        hold.resume(returning: true)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(route.phase, .playing)
        XCTAssertFalse(route.statusMessage.contains("已走到终点"))
        route.pause()
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
        XCTAssertNil(route.pathNotice)
    }

    func testLoadRestoresStraightFallbackNotice() {
        var saved = sampleSavedRoute(repeatMode: .once)
        saved.straightFallback = .all
        let route = makeRoute()
        route.load(saved)
        XCTAssertEqual(route.pathNotice, "沿路规划失败，已改用直线")
        let snapshot = route.makeSavedRoute(name: "学校", overwrite: true)
        XCTAssertEqual(snapshot?.straightFallback, .all)
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
        XCTAssertNotEqual(snapshot!.id, saved.id)
        let overwritten = route.makeSavedRoute(name: "操场", overwrite: true)!
        XCTAssertEqual(overwritten.id, saved.id)
        XCTAssertEqual(overwritten.name, "操场")
        XCTAssertEqual(overwritten.createdAt, saved.createdAt)
    }

    func testRemoveViaAtIndexAndReplaceNearbyVia() {
        let route = makeRoute()
        route.load(sampleSavedRoute(repeatMode: .once))
        let extra = CoordinateConverter.coordinatePair(
            lat: 22.4942,
            lon: 113.9514,
            mapCoordinateSystem: .wgs84
        )
        route.addVia(extra)
        XCTAssertEqual(route.vias.count, 2)

        route.removeVia(at: 0)
        XCTAssertEqual(route.vias.count, 1)
        XCTAssertEqual(route.vias[0].wgs84.latitude, extra.wgs84.latitude, accuracy: 0.000_000_1)

        let nearby = CoordinateConverter.coordinatePair(
            lat: extra.wgs84.latitude + 0.000_05,
            lon: extra.wgs84.longitude,
            mapCoordinateSystem: .wgs84
        )
        route.addVia(nearby)
        XCTAssertEqual(route.vias.count, 1)
        XCTAssertEqual(route.vias[0].wgs84.latitude, nearby.wgs84.latitude, accuracy: 0.000_000_1)
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

    func testPausedTravelModeChangeKeepsProgress() async {
        let previous = RouteDirections.provider
        RouteDirections.provider = DetourRouteDirections()
        defer { RouteDirections.provider = previous }

        let route = preparedRoute(repeatMode: .once)
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 20_000_000
        route.setSpeedKilometersPerHour(40)
        route.applyCoordinate = { _ in true }
        route.requestPlay()
        route.noteActivated()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        route.pause()

        let pausedProgress = route.progress
        XCTAssertGreaterThan(pausedProgress, 0.04)
        let revision = route.pathRevision
        let mode = route.travelMode
        route.applyTravelMode(mode == .walk ? .bike : .walk)
        route.setStart(CoordinateConverter.coordinatePair(lat: 22.5, lon: 114, mapCoordinateSystem: .wgs84))
        XCTAssertEqual(route.travelMode, mode)
        XCTAssertEqual(route.pathRevision, revision)
        XCTAssertEqual(route.phase, .paused)
        route.setSpeedKilometersPerHour(20)
        XCTAssertEqual(route.speedKilometersPerHour, 20, accuracy: 0.01)
        XCTAssertEqual(route.progress, pausedProgress, accuracy: 0.000_1)

        let expected = RoutePlayback.interpolate(path: route.path!, progress: pausedProgress)
        XCTAssertEqual(route.current?.wgs84.latitude ?? 0, expected.wgs84.latitude, accuracy: 0.000_05)
        XCTAssertEqual(route.current?.wgs84.longitude ?? 0, expected.wgs84.longitude, accuracy: 0.000_05)

        let entered = expectation(description: "恢复后的第一次定位写入")
        let hold = PlaybackWriteHold()
        route.applyCoordinate = { _ in
            await hold.wait(entered)
        }
        route.resume()
        await fulfillment(of: [entered], timeout: 2)

        XCTAssertEqual(route.progress, pausedProgress, accuracy: 0.03)
        XCTAssertGreaterThan(route.progress, 0.03)
        hold.resume(returning: true)
        route.pause()
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

private struct DetourRouteDirections: RouteDirectionsProviding {
    @MainActor
    func routePoints(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode
    ) async -> [CoordinatePair]? {
        let far = CoordinateConverter.coordinatePair(
            lat: start.wgs84.latitude + 0.1,
            lon: start.wgs84.longitude,
            mapCoordinateSystem: .wgs84
        )
        return [start, far, end]
    }
}

private final class PlaybackWriteHold: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait(_ entered: XCTestExpectation) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func resume(returning value: Bool) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}
