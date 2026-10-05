import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyModeCleanupTests: XCTestCase {
    private var defaults: UserDefaults!
    private let favorite = FavoriteLocation(
        name: "mock", latitude: 1, longitude: 1, accuracy: 5, mapCoordinateSystem: .wgs84
    )

    override func setUp() async throws {
        let suiteName = "ThirdPartyModeCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        self.defaults = defaults
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    }

    func testUnconfiguredRoundTripDoesNotContactThirdParty() async throws {
        let requester = FakeThirdPartyRequester(error: URLError(.cannotConnectToHost))
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        let mode = ProxyRuntimeModeStore(defaults: defaults, legacyDefaults: defaults)
        mode.setMode(.developerTunnel, disablesPreview: false)
        mode.markInitialized(.developerTunnel)
        mode.setMode(.thirdParty, disablesPreview: false)

        let cleanup = RuntimeModeSwitchCleanup.required(
            from: mode.mode, to: .developerTunnel,
            thirdPartyNeedsCleanup: manager.needsCoordinateCleanup(
                hasInitializedThirdParty: mode.isInitialized(.thirdParty)
            )
        )
        if cleanup.contains(.thirdPartyWLOC) { try await manager.clear() }
        mode.setMode(.developerTunnel, disablesPreview: false)

        XCTAssertTrue(cleanup.isEmpty)
        XCTAssertTrue(requester.requestedURLs.isEmpty)
        XCTAssertEqual(mode.mode, .developerTunnel)
    }

    func testFailedConnectionTestAloneDoesNotCreateCleanupObligation() async {
        let manager = ThirdPartyProxyManager(
            requester: FakeThirdPartyRequester(error: URLError(.timedOut)), defaults: defaults
        )
        do { _ = try await manager.query(); XCTFail("应报告检测失败") } catch {}
        XCTAssertFalse(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }

    func testInitializedClientStillRequiresClearWithoutNewTrackingKey() {
        let manager = ThirdPartyProxyManager(
            requester: FakeThirdPartyRequester(body: "not-json"), defaults: defaults
        )
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: true))
    }

    func testTimedOutSavePersistsCleanupObligationAcrossRestartAndQueryFailure() async {
        let requester = FakeThirdPartyRequester(error: URLError(.timedOut))
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        do { _ = try await manager.save(favorite); XCTFail("应报告保存超时") } catch {}
        XCTAssertNil(manager.activeSettings)

        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        do { _ = try await restored.query(); XCTFail("应报告检测失败") } catch {}
        XCTAssertTrue(restored.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }

    func testCoordinateMismatchStillRequiresClear() async {
        let manager = ThirdPartyProxyManager(
            requester: FakeThirdPartyRequester(body: #"{"success":true,"latitude":2,"longitude":2}"#),
            defaults: defaults
        )
        do { _ = try await manager.save(favorite); XCTFail("应拒绝不一致回读") } catch {}
        XCTAssertNil(manager.activeSettings)
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }

    func testQueryOfExistingCoordinatesPersistsCleanupObligation() async throws {
        let requester = FakeThirdPartyRequester(body: #"{"success":true,"latitude":1,"longitude":1}"#)
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        _ = try await manager.query()
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertTrue(restored.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }

    func testFailedClearKeepsObligationAndSuccessfulClearRemovesIt() async throws {
        let requester = FakeThirdPartyRequester(bodies: [
            #"{"success":true,"latitude":1,"longitude":1}"#,
            #"{"success":false,"error":"mock failure"}"#,
            #"{"success":true}"#
        ])
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        _ = try await manager.save(favorite)
        do { try await manager.clear(); XCTFail("应报告清理失败") } catch {}
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))

        try await manager.clear()
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertFalse(restored.needsCoordinateCleanup(hasInitializedThirdParty: false))
        XCTAssertTrue(restored.needsCoordinateCleanup(hasInitializedThirdParty: true))
    }

    func testSuspendedSaveNeverSentDoesNotCreateCleanupObligation() async {
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        manager.suspendWrites()
        do { _ = try await manager.save(favorite); XCTFail("应拒绝暂停后的写入") } catch {}
        XCTAssertTrue(requester.requestedURLs.isEmpty)
        XCTAssertFalse(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }

    func testInFlightSaveIsTrackedBeforeResponseAndSurvivesCancellation() async throws {
        let entered = expectation(description: "坐标请求已发送")
        let requester = ControlledThirdPartyRequester(entered: entered)
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        let save = Task { try await manager.save(favorite) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertTrue(restored.needsCoordinateCleanup(hasInitializedThirdParty: false))

        manager.suspendWrites()
        save.cancel()
        await requester.release()
        do { _ = try await save.value; XCTFail("应丢弃旧写入结果") } catch is CancellationError {}
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
        try await manager.clear()
        XCTAssertFalse(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }

    func testInFlightQueryConservativelyRequiresCleanup() async throws {
        let entered = expectation(description: "查询请求已发送")
        let requester = ControlledThirdPartyRequester(entered: entered)
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        let query = Task { try await manager.query() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
        manager.suspendWrites()
        await requester.release()
        do { _ = try await query.value; XCTFail("应丢弃旧查询结果") } catch is CancellationError {}
    }

    func testCleanupSnapshotSurvivesQueryFinishingBetweenSuspensionAndSwitchTask() async throws {
        let entered = expectation(description: "查询请求已发送")
        let requester = ControlledThirdPartyRequester(entered: entered)
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        let query = Task { try await manager.query() }
        await fulfillment(of: [entered], timeout: 2)
        let needsCleanup = manager.needsCoordinateCleanup(hasInitializedThirdParty: false)
        manager.suspendWrites()
        await requester.release()
        do { _ = try await query.value; XCTFail("应丢弃旧查询结果") } catch is CancellationError {}
        XCTAssertFalse(manager.isRequesting)
        XCTAssertNil(manager.activeSettings)

        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .developerTunnel, thirdPartyNeedsCleanup: needsCleanup
        ), [.thirdPartyWLOC])
        try await manager.clear()
        let actions = await requester.actions()
        XCTAssertEqual(actions, ["query", "clear"])
    }

    func testCancelledQueryThenFailedClearCannotBypassCleanupOnRetry() async throws {
        let entered = expectation(description: "查询请求已发送")
        let requester = ControlledThirdPartyRequester(entered: entered, failClear: true)
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        let query = Task { try await manager.query() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
        let submitted = expectation(description: "清理已排队")
        let clear = Task { submitted.fulfill(); try await manager.clear() }
        await fulfillment(of: [submitted], timeout: 2)
        await requester.release()
        do { _ = try await query.value; XCTFail("应丢弃旧查询结果") } catch is CancellationError {}
        do { try await clear.value; XCTFail("应报告清理失败") } catch is ThirdPartyProxyError {}

        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertTrue(restored.needsCoordinateCleanup(hasInitializedThirdParty: false))
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .developerTunnel,
            thirdPartyNeedsCleanup: restored.needsCoordinateCleanup(hasInitializedThirdParty: false)
        ), [.thirdPartyWLOC])
    }
}
