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
    func testSetupStoreDoesNotRetryAfterCancellation() async throws {
        let client = FakeIdeviceClient(results: [.tunnel, nil])
        let pushed = expectation(description: "first push")
        client.afterSet = { pushed.fulfill() }
        let store = try readyStore(client: client, tunnelRetryDelayNanoseconds: 5_000_000_000)

        let task = Task { await store.set(latitude: 22.5, longitude: 113.9) }
        await fulfillment(of: [pushed], timeout: 2)
        task.cancel()
        let failure = await task.value

        XCTAssertEqual(failure, .superseded)
        XCTAssertEqual(client.pushes.count, 1)
        XCTAssertFalse(store.isSimulating)
    }

    @MainActor
    func testClearSupersedesAnInFlightSet() async throws {
        let client = FakeIdeviceClient(results: [nil])
        let entered = expectation(description: "set entered")
        let resume = DispatchSemaphore(value: 0)
        client.beforeSet = {
            entered.fulfill()
            resume.wait()
        }
        let store = try readyStore(client: client)

        let setTask = Task { await store.set(latitude: 22.5, longitude: 113.9) }
        await fulfillment(of: [entered], timeout: 2)
        let clearFailure = await store.clear()
        resume.signal()
        let setFailure = await setTask.value

        XCTAssertNil(clearFailure)
        XCTAssertEqual(setFailure, .superseded)
        XCTAssertEqual(client.clears, 1)
        XCTAssertTrue(client.pushes.isEmpty)
        XCTAssertFalse(store.isSimulating)
    }

    @MainActor
    func testClearFailureKeepsSimulationActive() async throws {
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed])
        let store = try readyStore(client: client)

        let setFailure = await store.set(latitude: 22.5, longitude: 113.9)
        let clearFailure = await store.clear()

        XCTAssertNil(setFailure)
        XCTAssertEqual(clearFailure, .clearFailed)
        XCTAssertEqual(clearFailure?.message, "系统定位没有关掉，模拟仍在生效。")
        XCTAssertTrue(store.isSimulating)
        XCTAssertEqual(client.clears, 1)
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
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .preparing, to: .inactive))
        XCTAssertTrue(
            RouteLocationStop.shouldClearSimulation(
                from: .preparing,
                to: .inactive,
                activationWritePending: true
            )
        )
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
    func testSetAndClearRecordTimesWithoutOverwritingOnSupersede() async throws {
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed])
        let store = try readyStore(client: client, tunnelRetryDelayNanoseconds: 5_000_000_000)
        let setFailure = await store.set(latitude: 22.5, longitude: 113.9)
        XCTAssertNil(setFailure)
        XCTAssertNotNil(store.activity.lastSetAt)
        XCTAssertNil(store.activity.lastFailure)

        let failure = await store.clear()
        XCTAssertEqual(failure, .clearFailed)
        XCTAssertNotNil(store.activity.lastClearAt)
        XCTAssertEqual(store.activity.lastFailure, .clearFailed)
        XCTAssertTrue(store.activity.simulationMayStillBeActive)

        let setAt = store.activity.lastSetAt
        let clientForCancel = client
        let entered = expectation(description: "superseded set")
        clientForCancel.beforeSet = { entered.fulfill() }
        clientForCancel.results.append(.tunnel)
        let task = Task { await store.set(latitude: 1, longitude: 2) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        let superseded = await task.value
        XCTAssertEqual(superseded, .superseded)
        XCTAssertEqual(store.activity.lastFailure, .clearFailed)
        XCTAssertEqual(store.activity.lastSetAt, setAt)
    }

    @MainActor
    func testRetryClearReconnectsWhenHandleIsGone() async throws {
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed, nil])
        let store = try readyStore(client: client)
        let setFailure = await store.set(latitude: 22.5, longitude: 113.9)
        XCTAssertNil(setFailure)
        _ = await store.invalidateActiveSession()
        XCTAssertFalse(client.retainsSimulation)
        XCTAssertTrue(store.activity.simulationMayStillBeActive)

        let clearFailure = await store.clear()
        XCTAssertNil(clearFailure)
        XCTAssertEqual(client.reconnectClears, 1)
        XCTAssertFalse(store.activity.simulationMayStillBeActive)
        XCTAssertTrue(client.pushes.last?.pairingPath.contains("rp_pairing_file.plist") == true)
    }

    @MainActor
    func testReplaceInvalidatesOldSessionAndDeleteKeepsFileWhenClearFails() async throws {
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed, .clearFailed])
        let store = try readyStore(client: client)
        let setFailure = await store.set(latitude: 22.5, longitude: 113.9)
        XCTAssertNil(setFailure)
        let replacement = try PropertyListSerialization.data(
            fromPropertyList: ["kind": "replacement"],
            format: .xml,
            options: 0
        )
        try await store.importPairing(replacement)
        XCTAssertEqual(client.invalidations, 1)
        XCTAssertFalse(client.retainsSimulation)
        XCTAssertTrue(store.status.hasPairing)
        XCTAssertTrue(store.activity.simulationMayStillBeActive)

        let message = await store.deletePairing()
        XCTAssertEqual(message, RouteLocationPushFailure.clearFailed.message)
        XCTAssertTrue(store.status.hasPairing)
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
        isTunnelConnected: @escaping @MainActor () -> Bool = { true },
        tunnelRetryDelayNanoseconds: UInt64 = 1_000_000
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
            tunnelRetryDelayNanoseconds: tunnelRetryDelayNanoseconds
        )
        return RouteLocationSetupStore(pairingStore: pairingStore, client: client, environment: environment)
    }
}

private final class FakeIdeviceClient: IdeviceLocationPushing, @unchecked Sendable {
    private let lock = NSLock()
    private var clearResults: [RouteLocationPushFailure?]
    private var mutation: UInt64 = 0
    var results: [RouteLocationPushFailure?]
    private(set) var pushes: [(latitude: Double, longitude: Double, pairingPath: String)] = []
    private(set) var clears = 0
    private(set) var reconnectClears = 0
    private(set) var invalidations = 0
    var retainsSimulation = false
    var beforeSet: (@Sendable () -> Void)?
    var afterSet: (@Sendable () -> Void)?

    init(
        results: [RouteLocationPushFailure?],
        clearResults: [RouteLocationPushFailure?] = []
    ) {
        self.results = results
        self.clearResults = clearResults
    }

    func beginMutation() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        mutation &+= 1
        return mutation
    }

    func currentMutation() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return mutation
    }

    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome {
        beforeSet?()
        lock.lock()
        defer { lock.unlock() }
        guard mutation == self.mutation else { return .superseded }
        pushes.append((latitude, longitude, pairingPath))
        afterSet?()
        guard !results.isEmpty else {
            retainsSimulation = true
            return .finished(nil)
        }
        let failure = results.removeFirst()
        if failure == nil { retainsSimulation = true }
        return .finished(failure)
    }

    func clear(mutation: UInt64) -> IdeviceCommandOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard mutation == self.mutation else { return .superseded }
        clears += 1
        return finishClear()
    }

    func invalidate(mutation: UInt64) -> IdeviceCommandOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard mutation == self.mutation else { return .superseded }
        invalidations += 1
        let outcome = finishClear()
        retainsSimulation = false
        return outcome
    }

    func clearReconnecting(
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard mutation == self.mutation else { return .superseded }
        _ = deviceAddress
        reconnectClears += 1
        pushes.append((0, 0, pairingPath))
        return finishClear()
    }

    private func finishClear() -> IdeviceCommandOutcome {
        guard !clearResults.isEmpty else {
            retainsSimulation = false
            return .finished(nil)
        }
        let failure = clearResults.removeFirst()
        if failure == nil { retainsSimulation = false }
        return .finished(failure)
    }
}
