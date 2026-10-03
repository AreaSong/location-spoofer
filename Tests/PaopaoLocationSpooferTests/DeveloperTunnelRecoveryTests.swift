import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class DeveloperTunnelRecoveryTests: XCTestCase {
    private final class Network {
        var observation = DeveloperNetworkObservation()
        var tunnel = true
    }

    func testOfflineHotspotAndCellularAreIndependentOfDeviceService() async throws {
        for path in [
            DeveloperNetworkObservation(pathSatisfied: true, usesCellular: true),
            DeveloperNetworkObservation(pathSatisfied: false, usesWiFi: true),
            DeveloperNetworkObservation()
        ] {
            let network = Network()
            network.observation = path
            let client = FakeIdeviceClient(results: [nil, .tunnel, .tunnel])
            let store = try makeStore(client, network)
            let success = await store.set(latitude: 1, longitude: 2)
            XCTAssertNil(success)
            XCTAssertEqual(store.connectionSummary, "最近定位推送成功")
            XCTAssertEqual(store.simulationStatusText, "已开启")
            let failure = await store.set(latitude: 3, longitude: 4)
            XCTAssertNotNil(failure)
            XCTAssertEqual(client.pushes.count, 3)
            XCTAssertFalse(store.isSimulating)
            XCTAssertEqual(store.connectionSummary, "推送或清理失败，旧模拟可能仍生效")
            XCTAssertTrue(store.activity.simulationMayStillBeActive)
            XCTAssertEqual(store.simulationStatusText, "可能仍在模拟")
        }
    }

    func testWiFiCellularOfflineHotspotRetriesWithCurrentObservation() async throws {
        let network = Network()
        network.observation = .init(pathSatisfied: true, usesWiFi: true)
        let client = FakeIdeviceClient(results: [nil, .tunnel, .tunnel, .tunnel, nil])
        let store = try makeStore(client, network)
        _ = await store.set(latitude: 1, longitude: 2)
        network.observation = .init(pathSatisfied: true, usesCellular: true)
        let failure = await store.set(latitude: 3, longitude: 4)
        XCTAssertEqual(failure, .tunnelOnCellular)
        // 无公网热点可能仍以蜂窝作为默认路径；不将假设备结果绑定到网络值。
        let recovered = await store.set(latitude: 5, longitude: 6)
        XCTAssertNil(recovered)
        XCTAssertNil(store.activity.lastFailure)
        XCTAssertEqual(client.pushes.count, 5)
        XCTAssertEqual(client.pushes.last?.latitude, 5)
    }

    func testFailureUsesObservationAfterDeviceReturns() async throws {
        let network = Network()
        network.observation = .init(pathSatisfied: true, usesCellular: true)
        let client = FakeIdeviceClient(results: [.tunnel])
        let store = try makeStore(client, network, delays: [])
        let entered = expectation(description: "设备调用已开始")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        client.beforeSet = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        let task = Task { await store.set(latitude: 1, longitude: 2) }
        await fulfillment(of: [entered], timeout: 2)
        network.observation = .init(pathSatisfied: false, usesWiFi: true)
        release.signal()
        let failure = await task.value
        XCTAssertEqual(failure, .tunnel)
        XCTAssertEqual(store.activity.lastFailure, .tunnel)
    }

    func testNetworkRecoveryAfterFailedStopCannotReassertAndClearCanRetry() async throws {
        let network = Network()
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed, nil])
        let store = try makeStore(client, network)
        _ = await store.set(latitude: 1, longitude: 2)
        network.tunnel = false
        let failure = await store.clear()
        XCTAssertEqual(failure, .clearFailed)
        network.tunnel = true
        store.refresh()
        _ = await store.reassertIfNeeded()
        XCTAssertEqual(client.pushes.count, 1)
        XCTAssertTrue(store.activity.simulationMayStillBeActive)
        let cleared = await store.clear()
        XCTAssertNil(cleared)
        XCTAssertFalse(store.activity.simulationMayStillBeActive)
        XCTAssertEqual(store.simulationStatusText, "已关闭")
        _ = await store.reassertIfNeeded()
        XCTAssertEqual(client.pushes.count, 1)
    }

    func testStaleSessionReleasesBeforeOpeningAndWritesOnlyAfterConnection() async throws {
        let probe = RecoveryProbe()
        let client = IdeviceLocationClient(operations: probe.operations)
        let store = try makeStore(client, Network())
        let result = await store.set(latitude: 1, longitude: 2)
        XCTAssertNil(result)
        XCTAssertEqual(probe.events, ["stale-set", "release", "connect", "set"])
        XCTAssertTrue(client.retainsSimulation)
    }

    func testStopDuringFailedOldWriteDoesNotReconnect() async throws {
        let entered = expectation(description: "旧句柄写入正在进行")
        let probe = RecoveryProbe(entered: entered, blockConnect: false)
        let client = IdeviceLocationClient(operations: probe.operations)
        let store = try makeStore(client, Network())
        let pending = Task { await store.set(latitude: 1, longitude: 2) }
        await fulfillment(of: [entered], timeout: 2)
        store.suspendWrites()
        probe.release.signal()
        let result = await pending.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(probe.events, ["stale-set", "release"])
        _ = await store.reassertIfNeeded()
        XCTAssertEqual(probe.events.count, 2)
    }

    func testNewPointDuringReconnectPreventsOldPointWrite() async throws {
        let entered = expectation(description: "重连正在进行")
        let probe = RecoveryProbe(entered: entered, blockConnect: true)
        let client = IdeviceLocationClient(operations: probe.operations)
        let store = try makeStore(client, Network())
        let pending = Task { await store.set(latitude: 1, longitude: 2) }
        await fulfillment(of: [entered], timeout: 2)
        // 同步撤销旧代次；之后才让被阻塞的连接返回，避免依赖调度速度。
        _ = client.beginMutation()
        probe.release.signal()
        let result = await pending.value
        XCTAssertEqual(result, .superseded)
        let changed = await store.set(latitude: 3, longitude: 4)
        XCTAssertNil(changed)
        XCTAssertEqual(probe.coordinates, [3])
        XCTAssertEqual(probe.events, ["stale-set", "release", "connect", "release", "connect", "set"])
    }

    func testNewRequestRejectedByEnvironmentSupersedesInFlightSuccess() async throws {
        let network = Network()
        let client = FakeIdeviceClient(results: [nil])
        let store = try makeStore(client, network)
        let entered = expectation(description: "旧请求已开始")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        client.beforeSet = { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        let old = Task { await store.set(latitude: 1, longitude: 2) }
        await fulfillment(of: [entered], timeout: 2)
        network.tunnel = false
        let newer = await store.set(latitude: 3, longitude: 4)
        XCTAssertEqual(newer, .notReady(.tunnelDisconnected))
        release.signal()
        let stale = await old.value
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(store.activity.lastFailure, .notReady(.tunnelDisconnected))
        XCTAssertFalse(store.isSimulating)
        _ = await store.reassertIfNeeded()
        XCTAssertTrue(client.pushes.isEmpty)
    }

    private func makeStore(
        _ client: IdeviceLocationPushing, _ network: Network, delays: [UInt64] = [1_000_000]
    ) throws -> RouteLocationSetupStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pairing = RoutePairingStore(directoryURL: directory)
        try pairing.install(PropertyListSerialization.data(
            fromPropertyList: ["kind": "test"], format: .xml, options: 0
        ))
        let store = RouteLocationSetupStore(pairingStore: pairing, client: client, environment: .init(
            isVPNInstalled: { true }, isTunnelConnected: { network.tunnel }, deviceAddress: "mock",
            tunnelRetryDelaysNanoseconds: delays, networkObservation: { network.observation },
            waitForMaintenance: { try await Task.sleep(nanoseconds: 60_000_000_000) }
        ))
        addTeardownBlock {
            _ = await store.clear()
            try FileManager.default.removeItem(at: directory)
        }
        return store
    }
}

/// 所有设备 IO 都由 IdeviceLocationClient 的真实串行队列调用；测试只阻塞单个阶段。
private final class RecoveryProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation?
    private let blockConnect: Bool
    private var retained = true
    private var stale = true
    private var didBlock = false
    private(set) var events: [String] = []
    private(set) var coordinates: [Double] = []

    init(entered: XCTestExpectation? = nil, blockConnect: Bool = false) {
        self.entered = entered
        self.blockConnect = blockConnect
    }

    private func blockIfNeeded(connect: Bool) {
        guard let entered, blockConnect == connect, !didBlock else { return }
        didBlock = true
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
    }

    var operations: IdeviceLocationClient.DeviceOperations {
        .init(set: { [self] latitude, _ in
            if stale {
                events.append("stale-set")
                blockIfNeeded(connect: false)
                stale = false
                return .rejected
            }
            events.append("set")
            coordinates.append(latitude)
            return nil
        }, clear: { [self] in retained = false; return nil }, abandon: { [self] in
            events.append("release")
            retained = false
        }, retainsSimulation: { [self] in retained }, connect: { [self] in
            events.append("connect")
            blockIfNeeded(connect: true)
            retained = true
            return nil
        })
    }
}
