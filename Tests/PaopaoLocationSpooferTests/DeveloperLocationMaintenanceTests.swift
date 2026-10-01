import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class DeveloperLocationMaintenanceTests: XCTestCase {
    private final class Clock {
        var time: TimeInterval = 0
    }

    func testRetainedHandleDoesNotMaskExpiredDeviceSimulation() async throws {
        let client = FakeIdeviceClient(results: [nil, nil])
        let store = try makeStore(client: client)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        client.expireDeviceSimulation()

        XCTAssertTrue(store.status.tunnelConnected)
        XCTAssertTrue(client.retainsSimulation)
        XCTAssertFalse(client.deviceSimulationActive)
        let failure = await store.reassertIfNeeded()

        XCTAssertNil(failure)
        XCTAssertTrue(client.deviceSimulationActive)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertEqual(client.abandons, 0)
    }

    func testPeriodicMaintenanceUsesLatestPointAndSkipsRecentRouteWrites() async throws {
        let client = FakeIdeviceClient(results: [])
        let clock = Clock()
        let store = try makeStore(client: client, clock: clock)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        clock.time = 9
        _ = await store.set(latitude: 22.6, longitude: 114.0)

        clock.time = 10
        _ = await store.reassertIfNeeded(force: false)
        XCTAssertEqual(client.pushes.count, 2)
        clock.time = 19
        _ = await store.reassertIfNeeded(force: false)

        XCTAssertEqual(client.pushes.count, 3)
        XCTAssertEqual(client.pushes.last?.latitude, 22.6)
        XCTAssertEqual(client.pushes.last?.longitude, 114.0)
    }

    func testFailedInitialSetDoesNotBecomeAnAutomaticTarget() async throws {
        let client = FakeIdeviceClient(results: [.rejected, nil])
        let store = try makeStore(client: client)
        _ = await store.set(latitude: 22.5, longitude: 113.9)

        _ = await store.reassertIfNeeded()

        XCTAssertEqual(client.pushes.count, 1)
        XCTAssertFalse(client.deviceSimulationActive)
    }

    func testMaintenanceRunsWithoutTheViewTunnelMonitor() async throws {
        let client = FakeIdeviceClient(results: [])
        let clock = Clock()
        let store = try makeStore(client: client, clock: clock, automatic: true)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        store.startTunnelMonitor()
        store.stopTunnelMonitor()
        client.expireDeviceSimulation()
        let refreshed = expectation(description: "独立维持任务重新写入")
        client.afterSet = { refreshed.fulfill() }
        clock.time = 10

        await fulfillment(of: [refreshed], timeout: 2)
        // 等设备调用退出，服务才会更新写入时间；clear 同时验证维持任务可以结束。
        let failure = await store.clear()

        XCTAssertNil(failure)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertFalse(client.deviceSimulationActive)
    }

    func testClearSupersedesAQueuedMaintenanceWrite() async throws {
        let client = FakeIdeviceClient(results: [])
        let store = try makeStore(client: client)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        let entered = expectation(description: "补写进入设备队列")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        client.beforeSet = { entered.fulfill(); resume.wait() }
        let pending = Task { await store.reassertIfNeeded() }
        await fulfillment(of: [entered], timeout: 2)

        let cleared = await store.clear()
        resume.signal()
        let stale = await pending.value
        _ = await store.reassertIfNeeded()

        XCTAssertNil(cleared)
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(client.pushes.count, 1)
        XCTAssertFalse(client.deviceSimulationActive)
    }

    func testNewPointSupersedesAQueuedMaintenanceWrite() async throws {
        let client = FakeIdeviceClient(results: [])
        let store = try makeStore(client: client)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        let entered = expectation(description: "旧点补写进入设备队列")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        client.beforeSet = { entered.fulfill(); resume.wait() }
        let pending = Task { await store.reassertIfNeeded() }
        await fulfillment(of: [entered], timeout: 2)
        client.beforeSet = nil

        let changed = await store.set(latitude: 22.6, longitude: 114.0)
        resume.signal()
        let stale = await pending.value
        _ = await store.reassertIfNeeded()

        XCTAssertNil(changed)
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(client.pushes.map(\.latitude), [22.5, 22.6, 22.6])
    }

    func testMaintenanceDoesNotCancelAnInFlightUserWrite() async throws {
        let client = FakeIdeviceClient(results: [])
        let store = try makeStore(client: client)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        let entered = expectation(description: "用户新点进入设备队列")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        client.beforeSet = { entered.fulfill(); resume.wait() }
        let pending = Task { await store.set(latitude: 22.6, longitude: 114.0) }
        await fulfillment(of: [entered], timeout: 2)

        _ = await store.reassertIfNeeded()
        resume.signal()
        let changed = await pending.value

        XCTAssertNil(changed)
        XCTAssertEqual(client.pushes.map(\.latitude), [22.5, 22.6])
    }

    func testClearAndInvalidateFailuresStillDisableAutomaticWrites() async throws {
        let client = FakeIdeviceClient(results: [], clearResults: [.clearFailed, .clearFailed])
        let store = try makeStore(client: client)
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        let cleared = await store.clear()
        _ = await store.reassertIfNeeded()
        XCTAssertEqual(cleared, .clearFailed)
        XCTAssertEqual(client.pushes.count, 1)

        _ = await store.set(latitude: 22.6, longitude: 114.0)
        let invalidated = await store.invalidateActiveSession()
        _ = await store.reassertIfNeeded()
        XCTAssertEqual(invalidated, .clearFailed)
        XCTAssertEqual(client.pushes.count, 2)
    }

    func testTunnelLossRetainsTargetForRecoveryAndThrottlesAttempts() async throws {
        let client = FakeIdeviceClient(results: [])
        let clock = Clock()
        var connected = true
        let store = try makeStore(client: client, clock: clock, connected: { connected })
        _ = await store.set(latitude: 22.5, longitude: 113.9)
        connected = false
        clock.time = 10
        let failed = await store.reassertIfNeeded(force: false)
        XCTAssertEqual(failed, .notReady(.tunnelDisconnected))

        connected = true
        clock.time = 11
        _ = await store.reassertIfNeeded(force: false)
        XCTAssertEqual(client.pushes.count, 1)
        clock.time = 20
        _ = await store.reassertIfNeeded(force: false)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertEqual(client.pushes.last?.latitude, 22.5)
    }

    private func makeStore(
        client: FakeIdeviceClient,
        clock: Clock = Clock(),
        automatic: Bool = false,
        connected: @escaping @MainActor () -> Bool = { true }
    ) throws -> RouteLocationSetupStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeveloperLocationMaintenanceTests.\(UUID().uuidString)")
        let pairing = RoutePairingStore(directoryURL: directory)
        try pairing.install(PropertyListSerialization.data(
            fromPropertyList: ["kind": "rppairing"], format: .xml, options: 0
        ))
        let environment = RouteLocationEnvironment(
            isVPNInstalled: { true }, isTunnelConnected: connected,
            deviceAddress: "10.7.0.1", tunnelRetryDelaysNanoseconds: [],
            isCellularWithoutWiFi: { false }, monotonicTime: { clock.time },
            waitForMaintenance: {
                try await Task.sleep(nanoseconds: automatic ? 20_000_000 : 60_000_000_000)
            }
        )
        let store = RouteLocationSetupStore(pairingStore: pairing, client: client, environment: environment)
        addTeardownBlock {
            _ = await store.clear()
            try FileManager.default.removeItem(at: directory)
        }
        return store
    }
}
