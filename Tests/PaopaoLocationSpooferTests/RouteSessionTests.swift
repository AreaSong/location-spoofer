import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class RouteSessionTests: XCTestCase {
    func testPushFailureKeepsProgressAndRestartClearsIt() async {
        let suite = "RouteSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = RoutePlaybackController(
            preferenceStore: RoutePlaybackPreferenceStore(defaults: defaults),
            sessionStore: RouteSessionStore(defaults: defaults)
        )
        let start = CoordinateConverter.coordinatePair(lat: 22.49, lon: 113.95, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.50, lon: 113.95, mapCoordinateSystem: .wgs84)
        route.load(SavedRoute(
            name: "学校",
            start: start,
            end: end,
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            pathPoints: [start, end]
        ))
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 20_000_000
        route.applyCoordinate = { _ in false }
        route.requestPlay()
        route.noteActivated()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(route.phase, .paused)
        XCTAssertEqual(route.interruption, .pushFailed)
        let kept = route.progress
        XCTAssertNotNil(route.sessionStore.load())
        var writes = 0
        route.applyCoordinate = { _ in
            writes += 1
            return true
        }
        XCTAssertEqual(writes, 0)

        route.resetProgressForRestart()
        XCTAssertEqual(route.progress, 0)
        XCTAssertEqual(route.phase, .preparing)
        XCTAssertGreaterThanOrEqual(kept, 0)
    }

    func testRecoverySeeksWithoutWritingLocation() {
        let suite = "RouteSessionTests.recover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = RoutePlaybackController(
            preferenceStore: RoutePlaybackPreferenceStore(defaults: defaults),
            sessionStore: RouteSessionStore(defaults: defaults)
        )
        let start = CoordinateConverter.coordinatePair(lat: 22.49, lon: 113.95, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.50, lon: 113.95, mapCoordinateSystem: .wgs84)
        var writes = 0
        route.applyCoordinate = { _ in
            writes += 1
            return true
        }
        let session = RouteSession(
            routeID: nil,
            name: "学校",
            start: start,
            end: end,
            viaPoints: [],
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            straightFallback: nil,
            progress: 0.4,
            elapsed: 12,
            headingForward: true,
            interruption: .playing,
            updatedAt: Date()
        )
        route.applyRecovery(session)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(route.phase, .paused)
        XCTAssertEqual(route.progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(route.interruption, .userPaused)
    }

    func testExpiredSessionIsNotRecoverable() {
        let suite = "RouteSessionTests.expired.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RouteSessionStore(defaults: defaults)
        let start = CoordinateConverter.coordinatePair(lat: 22.49, lon: 113.95, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.50, lon: 113.95, mapCoordinateSystem: .wgs84)
        store.save(RouteSession(
            routeID: nil,
            name: "旧路线",
            start: start,
            end: end,
            viaPoints: [],
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            straightFallback: nil,
            progress: 0.2,
            elapsed: 1,
            headingForward: true,
            interruption: .userPaused,
            updatedAt: Date().addingTimeInterval(-(RouteSession.lifetime + 10))
        ))
        XCTAssertNil(store.load())
    }
}
