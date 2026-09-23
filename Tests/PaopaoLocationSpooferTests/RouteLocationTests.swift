import Combine
import XCTest
@testable import PaopaoLocationSpoofer

final class RouteLocationTests: XCTestCase {
    func testGateBlocksUntilTunnelAndPairingAreReady() {
        XCTAssertEqual(
            RouteLocationStatus(vpnInstalled: false, tunnelConnected: false, hasPairing: false).readiness,
            .needsInstall
        )
        XCTAssertEqual(
            RouteLocationStatus(vpnInstalled: true, tunnelConnected: false, hasPairing: true).readiness,
            .tunnelDisconnected
        )
        XCTAssertEqual(
            RouteLocationStatus(vpnInstalled: true, tunnelConnected: true, hasPairing: false).readiness,
            .needsPairing
        )
        XCTAssertEqual(
            RouteLocationStatus(vpnInstalled: true, tunnelConnected: true, hasPairing: true).readiness,
            .ready
        )
        XCTAssertNotNil(RouteLocationReadiness.needsInstall.blockingMessage)
        XCTAssertNil(RouteLocationReadiness.ready.blockingMessage)
    }

    @MainActor
    func testLaunchRefusesWhenDeveloperLocationIsNotReady() {
        let route = RoutePlaybackController(preferenceStore: RoutePlaybackPreferenceStore(defaults: isolatedDefaults()))
        let message = RouteLocationLaunch.prepare(route, readiness: .tunnelDisconnected)
        XCTAssertEqual(message, RouteLocationReadiness.tunnelDisconnected.blockingMessage)
        XCTAssertFalse(route.ignoresWriteGate)
        XCTAssertEqual(route.statusMessage, message)
    }

    @MainActor
    func testLaunchArmsEverySamplePushWhenReady() {
        let route = RoutePlaybackController(preferenceStore: RoutePlaybackPreferenceStore(defaults: isolatedDefaults()))
        XCTAssertNil(RouteLocationLaunch.prepare(route, readiness: .ready))
        XCTAssertTrue(route.ignoresWriteGate)
        XCTAssertEqual(route.pushFailureMessage, RouteLocationPushFailure.rejected.message)
    }

    @MainActor
    func testSpoofSessionLaunchKeepsTheWriteGate() {
        let route = RoutePlaybackController(preferenceStore: RoutePlaybackPreferenceStore(defaults: isolatedDefaults()))
        XCTAssertNil(RouteLocationLaunch.prepare(route, readiness: .ready))
        RouteLocationLaunch.prepareForSpoofSession(route)
        XCTAssertFalse(route.ignoresWriteGate)
        XCTAssertEqual(route.pushFailureMessage, RouteLocationLaunch.spoofSessionFailureMessage)
    }

    @MainActor
    func testSetupStoreRetriesOnceWhenTheTunnelIsBusy() async throws {
        let client = FakeIdeviceClient(results: [.tunnel, nil])
        let store = try readyStore(client: client)

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertNil(failure)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertTrue(store.isSimulating)
    }

    @MainActor
    func testSetupStoreReportsADroppedTunnelInsteadOfARejectedPush() async throws {
        let client = FakeIdeviceClient(results: [.rejected])
        // 初始化和推送前各探测一次隧道都在线，推送失败后的第三次探测发现隧道已断。
        var probes = 0
        let store = try readyStore(client: client, isTunnelConnected: {
            probes += 1
            return probes <= 2
        })

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(failure, .notReady(.tunnelDisconnected))
        XCTAssertEqual(client.pushes.count, 1)
        XCTAssertFalse(store.isSimulating)
    }

    @MainActor
    func testSetupStoreDoesNotPushBeforeReady() async throws {
        let client = FakeIdeviceClient(results: [nil])
        let store = try readyStore(client: client, isVPNInstalled: { false })

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(failure, .notReady(.needsInstall))
        XCTAssertTrue(client.pushes.isEmpty)
    }

    func testStopAndFinishClearSimulationButPauseDoesNot() {
        XCTAssertTrue(RouteLocationStop.shouldClearSimulation(from: .playing, to: .inactive))
        XCTAssertTrue(RouteLocationStop.shouldClearSimulation(from: .paused, to: .inactive))
        XCTAssertTrue(RouteLocationStop.shouldClearSimulation(from: .playing, to: .finished))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .playing, to: .paused))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .preparing, to: .playing))
    }

    func testPairingStoreRejectsPlainTextAndKeepsAPlist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutePairingTests.\(UUID().uuidString)", isDirectory: true)
        let store = RoutePairingStore(directoryURL: directory)
        XCTAssertThrowsError(try store.install(Data("not a pairing file".utf8))) { error in
            XCTAssertEqual(error as? RoutePairingImportError, .invalidContents)
        }
        XCTAssertFalse(store.hasPairingFile)

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["kind": "rppairing"],
            format: .xml,
            options: 0
        )
        try store.install(plist)
        XCTAssertTrue(store.hasPairingFile)
        XCTAssertTrue(store.isExcludedFromBackup)
        try store.remove()
        XCTAssertFalse(store.hasPairingFile)
    }

    @MainActor
    func testPushFailurePausesWithTheDeveloperMessage() async {
        let route = loadedRoute()
        route.ignoresWriteGate = true
        route.pushFailureMessage = RouteLocationPushFailure.rejected.message
        route.applyCoordinate = { _ in false }
        route.requestPlay()
        route.noteActivated()

        let paused = expectation(description: "route pauses")
        let token = route.$phase.sink { phase in
            if phase == .paused { paused.fulfill() }
        }
        await fulfillment(of: [paused], timeout: 2)
        token.cancel()
        XCTAssertEqual(route.statusMessage, RouteLocationPushFailure.rejected.message)
    }

    @MainActor
    func testEverySamplePushDoesNotWaitForTheDistanceGate() async {
        let route = loadedRoute()
        route.tickIntervalNanoseconds = 15_000_000
        route.ignoresWriteGate = true
        var writes = 0
        route.applyCoordinate = { _ in
            writes += 1
            return true
        }
        route.requestPlay()
        route.noteActivated()
        try? await Task.sleep(nanoseconds: 70_000_000)
        route.pause()
        XCTAssertGreaterThan(writes, 1)
    }

    @MainActor
    private func loadedRoute() -> RoutePlaybackController {
        let route = RoutePlaybackController(preferenceStore: RoutePlaybackPreferenceStore(defaults: isolatedDefaults()))
        let start = CoordinateConverter.coordinatePair(lat: 22.494, lon: 113.951, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.50, lon: 113.951, mapCoordinateSystem: .wgs84)
        route.load(SavedRoute(
            name: "测试",
            start: start,
            end: end,
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            pathPoints: [start, end]
        ))
        return route
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "RouteLocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func readyStore(
        client: FakeIdeviceClient,
        isVPNInstalled: @escaping @MainActor () -> Bool = { true },
        isTunnelConnected: @escaping @MainActor () -> Bool = { true }
    ) throws -> RouteLocationSetupStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteLocationSetupStoreTests.\(UUID().uuidString)", isDirectory: true)
        let pairingStore = RoutePairingStore(directoryURL: directory)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["kind": "rppairing"],
            format: .xml,
            options: 0
        )
        try pairingStore.install(plist)
        let environment = RouteLocationEnvironment(
            isVPNInstalled: isVPNInstalled,
            isTunnelConnected: isTunnelConnected,
            deviceAddress: "10.7.0.1",
            tunnelRetryDelayNanoseconds: 1_000_000
        )
        return RouteLocationSetupStore(pairingStore: pairingStore, client: client, environment: environment)
    }
}

private final class FakeIdeviceClient: IdeviceLocationPushing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [RouteLocationPushFailure?]
    private(set) var pushes: [(latitude: Double, longitude: Double)] = []
    private(set) var clears = 0

    init(results: [RouteLocationPushFailure?]) {
        self.results = results
    }

    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String
    ) -> RouteLocationPushFailure? {
        lock.lock()
        defer { lock.unlock() }
        pushes.append((latitude, longitude))
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        clears += 1
    }
}
