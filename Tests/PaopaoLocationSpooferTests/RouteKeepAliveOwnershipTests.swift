import Combine
import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class RouteKeepAliveOwnershipTests: XCTestCase {
    override func tearDown() {
        BackgroundKeepAlive.shared.stop()
        super.tearDown()
    }

    func testReleasingRouteKeepsProxyOwner() {
        let keepAlive = BackgroundKeepAlive.shared
        keepAlive.retain(.proxy)
        keepAlive.retain(.routePlayback)

        keepAlive.release(.routePlayback)

        XCTAssertTrue(keepAlive.holds(.proxy))
        XCTAssertFalse(keepAlive.holds(.routePlayback))
        XCTAssertTrue(keepAlive.isEnabled)

        keepAlive.release(.proxy)

        XCTAssertFalse(keepAlive.holds(.proxy))
        XCTAssertFalse(keepAlive.isEnabled)
    }

    func testPauseAndExitReleaseOnlyTheRoute() {
        let keepAlive = BackgroundKeepAlive.shared
        keepAlive.retain(.proxy)
        let route = makeRoute()
        route.requestPlay()
        route.noteActivated()

        XCTAssertTrue(keepAlive.holds(.routePlayback))
        route.pause()
        XCTAssertEqual(route.phase, .paused)
        XCTAssertFalse(keepAlive.holds(.routePlayback))
        XCTAssertTrue(keepAlive.holds(.proxy))

        route.resume()
        XCTAssertTrue(keepAlive.holds(.routePlayback))
        route.exit()
        XCTAssertEqual(route.phase, .inactive)
        XCTAssertFalse(keepAlive.holds(.routePlayback))
        XCTAssertTrue(keepAlive.holds(.proxy))
    }

    func testNaturalFinishReleasesRouteAndLeavesImport() async {
        let keepAlive = BackgroundKeepAlive.shared
        keepAlive.retain(.thirdPartyImport)
        let route = makeRoute()
        route.tickIntervalNanoseconds = 20_000_000
        route.ignoresWriteGate = true
        route.applyCoordinate = { _ in true }
        route.setSpeedKilometersPerHour(40)
        route.requestPlay()
        route.noteActivated()

        let finished = expectation(description: "route finishes")
        let token = route.$phase.sink { phase in
            if phase == .finished { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 4)
        token.cancel()

        XCTAssertFalse(keepAlive.holds(.routePlayback))
        XCTAssertTrue(keepAlive.holds(.thirdPartyImport))
        XCTAssertTrue(keepAlive.isEnabled)
    }

    private func makeRoute() -> RoutePlaybackController {
        let suite = "RouteKeepAliveOwnershipTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let route = RoutePlaybackController(preferenceStore: RoutePlaybackPreferenceStore(defaults: defaults))
        let start = CoordinateConverter.coordinatePair(lat: 22.494, lon: 113.951, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.49414, lon: 113.951, mapCoordinateSystem: .wgs84)
        route.load(SavedRoute(
            name: "短途",
            start: start,
            end: end,
            travelMode: .bike,
            speedKilometersPerHour: 40,
            offsetMeters: 0,
            repeatMode: .once,
            pathPoints: [start, end]
        ))
        return route
    }
}
