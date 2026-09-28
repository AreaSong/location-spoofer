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
        XCTAssertTrue(RouteLocationPushFailure.tunnel.message.contains("客户端"))
        XCTAssertTrue(RouteLocationPushFailure.tunnel.message.contains("划掉"))
        XCTAssertTrue(RouteLocationPushFailure.tunnel.message.contains("Wi-Fi"))
        XCTAssertTrue(RouteLocationPushFailure.tunnelOnCellular.message.contains("流量"))
        XCTAssertTrue(RouteLocationPushFailure.tunnelOnCellular.message.contains("Wi-Fi"))
        XCTAssertTrue(DeveloperTunnelHelp.connectionChecks.contains("必须点 Connect"))
        XCTAssertTrue(DeveloperTunnelHelp.connectionChecks.contains("只开流量、关掉 Wi-Fi"))
        XCTAssertTrue(DeveloperTunnelHelp.connectionChecks.contains("自己开个人热点不算"))
    }

    func testTunnelInterfaceDetectionAcceptsPrivateTunnelAddresses() {
        XCTAssertTrue(LocalDevVPN.hasTunnelInterface(in: ["10.7.0.1"]))
        XCTAssertTrue(LocalDevVPN.hasTunnelInterface(in: ["10.7.1.1"]))
        XCTAssertTrue(LocalDevVPN.hasTunnelInterface(in: ["172.20.10.1"]))
        XCTAssertTrue(LocalDevVPN.hasTunnelInterface(in: ["192.168.1.5"]))
        XCTAssertTrue(LocalDevVPN.hasTunnelInterface(in: ["10.8.0.1"]))
        XCTAssertFalse(LocalDevVPN.hasTunnelInterface(in: ["8.8.8.8"]))
        XCTAssertFalse(LocalDevVPN.hasTunnelInterface(in: ["10.7.0.0"]))
        XCTAssertFalse(LocalDevVPN.hasTunnelInterface(in: []))
    }

    func testTunnelEndpointsAcceptCustomSubnetsAndSkipNetworkAddresses() {
        XCTAssertEqual(
            LocalDevVPN.tunnelEndpoints(
                preferred: "10.7.0.1",
                localAddresses: ["10.7.0.0", "192.168.1.2"],
                peerAddresses: ["10.7.0.1"]
            ),
            ["10.7.0.1", "192.168.1.2", "10.7.1.1", "10.7.0.2", "127.0.0.1"]
        )
        XCTAssertEqual(
            LocalDevVPN.tunnelEndpoints(
                preferred: "10.7.0.1",
                localAddresses: ["172.20.10.1"],
                peerAddresses: ["172.20.10.2"]
            ),
            ["10.7.0.1", "172.20.10.2", "172.20.10.1", "10.7.1.1", "10.7.0.2", "127.0.0.1"]
        )
        XCTAssertFalse(LocalDevVPN.isUsableHost("10.7.0.0"))
        XCTAssertTrue(LocalDevVPN.isUsableHost("10.7.0.1"))
        XCTAssertTrue(LocalDevVPN.isUsableHost("172.20.10.1"))
        XCTAssertTrue(LocalDevVPN.isUsableHost("192.168.1.5"))
        XCTAssertFalse(LocalDevVPN.isUsableHost("1.1.1.1"))
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
    func testSetupStoreRetriesWhenTheTunnelIsBusy() async throws {
        let client = FakeIdeviceClient(results: [.tunnel, nil])
        let store = try readyStore(client: client)

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertNil(failure)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertTrue(store.isSimulating)
    }

    @MainActor
    func testSetupStoreRetriesUntilTheTunnelRecovers() async throws {
        let client = FakeIdeviceClient(results: [.tunnel, .tunnel, nil])
        let store = try readyStore(
            client: client,
            tunnelRetryDelaysNanoseconds: [1_000_000, 1_000_000]
        )

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertNil(failure)
        XCTAssertEqual(client.pushes.count, 3)
        XCTAssertTrue(store.isSimulating)
    }

    @MainActor
    func testTunnelFlapKeepsTheLiveSimulation() async throws {
        let client = FakeIdeviceClient(results: [nil])
        var connected = true
        let store = try readyStore(client: client, isTunnelConnected: { connected })

        let failure = await store.set(latitude: 22.5, longitude: 113.9)
        XCTAssertNil(failure)
        XCTAssertTrue(client.retainsSimulation)

        connected = false
        store.refresh()
        connected = true
        store.refresh()

        XCTAssertEqual(client.abandons, 0)
        XCTAssertTrue(client.retainsSimulation)
        XCTAssertTrue(store.isSimulating)
        XCTAssertFalse(store.activity.simulationMayStillBeActive)
        XCTAssertEqual(store.readiness, .ready)
        let reasserted = await store.reassertIfNeeded(latitude: 22.6, longitude: 114.0)
        XCTAssertNil(reasserted)
        XCTAssertEqual(client.pushes.count, 1)
    }

    @MainActor
    func testReassertReconnectsOnlyAfterTheHandleIsGone() async throws {
        let client = FakeIdeviceClient(results: [.rejected, nil])
        let store = try readyStore(client: client)

        let failure = await store.set(latitude: 22.5, longitude: 113.9)
        XCTAssertEqual(failure, .rejected)
        XCTAssertFalse(client.retainsSimulation)

        let reasserted = await store.reassertIfNeeded(latitude: 22.5, longitude: 113.9)
        XCTAssertNil(reasserted)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertTrue(client.retainsSimulation)
        XCTAssertTrue(store.isSimulating)
    }

    @MainActor
    func testResetTunnelCacheKeepsPairingAndDropsTheSession() async throws {
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed])
        let store = try readyStore(client: client)
        let setFailure = await store.set(latitude: 22.5, longitude: 113.9)
        XCTAssertNil(setFailure)
        XCTAssertTrue(store.status.hasPairing)

        let message = await store.resetTunnelCache()

        XCTAssertTrue(message.contains("可能还停在虚拟点"))
        XCTAssertTrue(store.status.hasPairing)
        XCTAssertFalse(client.retainsSimulation)
        XCTAssertGreaterThanOrEqual(client.abandons, 1)
        XCTAssertFalse(store.isSimulating)
        XCTAssertTrue(store.activity.simulationMayStillBeActive)
    }

    @MainActor
    func testResetTunnelCacheWithoutASessionStillSucceeds() async throws {
        let client = FakeIdeviceClient(results: [nil])
        let store = try readyStore(client: client)

        let message = await store.resetTunnelCache()

        XCTAssertEqual(message, "隧道会话已清理。配对文件还在。")
        XCTAssertTrue(store.status.hasPairing)
        XCTAssertFalse(store.isSimulating)
    }

    @MainActor
    func testFailedPushAbandonsTheHalfOpenTunnel() async throws {
        let client = FakeIdeviceClient(results: [.rejected])
        let store = try readyStore(client: client)

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(failure, .rejected)
        XCTAssertEqual(client.abandons, 1)
        XCTAssertFalse(client.retainsSimulation)
    }

    @MainActor
    func testSetupStoreExplainsCellularWithoutRetrying() async throws {
        let client = FakeIdeviceClient(results: [.tunnel, .tunnel, .tunnel])
        let store = try readyStore(
            client: client,
            tunnelRetryDelaysNanoseconds: [1_000_000, 1_000_000],
            isCellularWithoutWiFi: { true }
        )

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(failure, .tunnelOnCellular)
        XCTAssertEqual(client.pushes.count, 1)
        XCTAssertFalse(store.isSimulating)
        XCTAssertEqual(store.activity.lastFailure, .tunnelOnCellular)
    }

    @MainActor
    func testSetupStoreGivesUpAfterTunnelRetries() async throws {
        let client = FakeIdeviceClient(results: [.tunnel, .tunnel, .tunnel])
        let store = try readyStore(
            client: client,
            tunnelRetryDelaysNanoseconds: [1_000_000, 1_000_000]
        )

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(failure, .tunnel)
        XCTAssertEqual(client.pushes.count, 3)
        XCTAssertFalse(store.isSimulating)
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
        let store = try readyStore(client: client, tunnelRetryDelaysNanoseconds: [5_000_000_000])

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
    func testSetupStoreTreatsALiveTunnelAsInstalled() async throws {
        let client = FakeIdeviceClient(results: [nil])
        let store = try readyStore(client: client, isVPNInstalled: { false })

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertNil(failure)
        XCTAssertTrue(store.status.vpnInstalled)
        XCTAssertEqual(client.pushes.count, 1)
    }

    @MainActor
    func testSetupStoreDoesNotPushBeforeReady() async throws {
        let client = FakeIdeviceClient(results: [nil])
        let store = try readyStore(
            client: client,
            isVPNInstalled: { false },
            isTunnelConnected: { false }
        )

        let failure = await store.set(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(failure, .notReady(.needsInstall))
        XCTAssertTrue(client.pushes.isEmpty)
    }

    func testDeveloperLocationKeepAliveStaysUpWhileTheSimulationIsHeld() {
        XCTAssertTrue(DeveloperLocationKeepAlive.shouldHold(
            preview: false,
            mode: .developerTunnel,
            isSimulating: true,
            spoofState: .idle,
            routePhase: .inactive
        ))
        XCTAssertTrue(DeveloperLocationKeepAlive.shouldHold(
            preview: false,
            mode: .developerTunnel,
            isSimulating: false,
            spoofState: .active,
            routePhase: .inactive
        ))
        XCTAssertTrue(DeveloperLocationKeepAlive.shouldHold(
            preview: false,
            mode: .developerTunnel,
            isSimulating: false,
            spoofState: .idle,
            routePhase: .playing
        ))
        XCTAssertFalse(DeveloperLocationKeepAlive.shouldHold(
            preview: false,
            mode: .developerTunnel,
            isSimulating: false,
            spoofState: .idle,
            routePhase: .paused
        ))
        XCTAssertFalse(DeveloperLocationKeepAlive.shouldHold(
            preview: true,
            mode: .developerTunnel,
            isSimulating: true,
            spoofState: .active,
            routePhase: .playing
        ))
        XCTAssertFalse(DeveloperLocationKeepAlive.shouldHold(
            preview: false,
            mode: .localWiFi,
            isSimulating: true,
            spoofState: .active,
            routePhase: .playing
        ))
    }

    func testStopAndFinishKeepSimulationInsteadOfClearing() {
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .playing, to: .inactive))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .paused, to: .inactive))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .playing, to: .finished))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .playing, to: .paused))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .preparing, to: .playing))
        XCTAssertFalse(RouteLocationStop.shouldClearSimulation(from: .preparing, to: .inactive))
        XCTAssertFalse(
            RouteLocationStop.shouldClearSimulation(
                from: .preparing,
                to: .inactive,
                activationWritePending: true
            )
        )
    }

    func testExitAndFinishHandoffToSpot() {
        XCTAssertTrue(RouteLocationStop.shouldHandoffToSpot(from: .playing, to: .inactive))
        XCTAssertTrue(RouteLocationStop.shouldHandoffToSpot(from: .paused, to: .inactive))
        XCTAssertTrue(RouteLocationStop.shouldHandoffToSpot(from: .playing, to: .finished))
        XCTAssertTrue(RouteLocationStop.shouldHandoffToSpot(from: .paused, to: .finished))
        XCTAssertTrue(RouteLocationStop.shouldHandoffToSpot(from: .finished, to: .inactive))
        XCTAssertTrue(
            RouteLocationStop.shouldHandoffToSpot(
                from: .preparing,
                to: .inactive,
                activationWritePending: true
            )
        )
        XCTAssertTrue(
            RouteLocationStop.shouldHandoffToSpot(
                from: .preparing,
                to: .inactive,
                isStoppedKeepingLocation: true
            )
        )
        XCTAssertFalse(RouteLocationStop.shouldHandoffToSpot(from: .playing, to: .paused))
        XCTAssertFalse(RouteLocationStop.shouldHandoffToSpot(from: .preparing, to: .playing))
        XCTAssertFalse(RouteLocationStop.shouldHandoffToSpot(from: .preparing, to: .inactive))
        XCTAssertFalse(
            RouteLocationStop.shouldHandoffToSpot(
                from: .preparing,
                to: .preparing,
                activationWritePending: true
            )
        )
    }

    func testKeptCoordinatePrefersLastRouteWriteOverSessionSpot() {
        let last = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let kept = RouteLocationStop.keptCoordinate(
            writtenLatitude: 22.5,
            writtenLongitude: 113.9,
            lastWritten: last
        )
        XCTAssertEqual(kept?.wgs84.latitude ?? 0, last.wgs84.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(kept?.wgs84.longitude ?? 0, last.wgs84.longitude, accuracy: 0.000_000_1)
        XCTAssertEqual(
            RouteLocationStop.keptCoordinate(
                writtenLatitude: 22.5,
                writtenLongitude: 113.9,
                lastWritten: nil
            )?.wgs84.latitude ?? 0,
            22.5,
            accuracy: 0.000_000_1
        )
        XCTAssertNil(
            RouteLocationStop.keptCoordinate(
                writtenLatitude: nil,
                writtenLongitude: nil,
                lastWritten: nil
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

    func testPairingHostIdentityPrefersTheFileIdentifier() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "identifier": "585DDC72-CDC4-3CB8-BA09-0E998DE51352",
                "name": "MacBook"
            ],
            format: .xml,
            options: 0
        )
        XCTAssertEqual(
            RoutePairingStore.hostIdentity(in: plist),
            "585DDC72-CDC4-3CB8-BA09-0E998DE51352"
        )
        let namedOnly = try PropertyListSerialization.data(
            fromPropertyList: ["name": "PaopaoLocation"],
            format: .xml,
            options: 0
        )
        XCTAssertEqual(RoutePairingStore.hostIdentity(in: namedOnly), "PaopaoLocation")
        XCTAssertNil(RoutePairingStore.hostIdentity(in: Data("not plist".utf8)))
    }

    @MainActor
    func testSetAndClearRecordTimesWithoutOverwritingOnSupersede() async throws {
        let client = FakeIdeviceClient(results: [nil], clearResults: [.clearFailed])
        let store = try readyStore(client: client, tunnelRetryDelaysNanoseconds: [5_000_000_000])
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
        tunnelRetryDelaysNanoseconds: [UInt64] = [1_000_000],
        isCellularWithoutWiFi: @escaping @MainActor () -> Bool = { false }
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
            tunnelRetryDelaysNanoseconds: tunnelRetryDelaysNanoseconds,
            isCellularWithoutWiFi: isCellularWithoutWiFi
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
    private(set) var abandons = 0
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

    func abandonSession() {
        lock.lock()
        defer { lock.unlock() }
        abandons += 1
        retainsSimulation = false
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
