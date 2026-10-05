import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyCleanupEvidenceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let suite = "ThirdPartyCleanupEvidenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    }

    func testConnectionHistoryAloneDoesNotRequireCleanup() {
        let manager = ThirdPartyProxyManager(requester: FakeThirdPartyRequester(body: "not-json"), defaults: defaults)
        defaults.set(true, forKey: "thirdPartyRuntimeModeInitialized")
        XCTAssertFalse(manager.needsCoordinateCleanup())
    }

    func testFailedClearWithoutCoordinatesDoesNotCreatePendingState() async {
        let manager = ThirdPartyProxyManager(requester: FakeThirdPartyRequester(body: "not-json"), defaults: defaults)
        do { try await manager.clear(); XCTFail("清理请求应失败") } catch {}
        XCTAssertFalse(manager.needsCoordinateCleanup())
    }

    func testNeverUsedThirdPartyDoesNotRequireClearForAppMode() {
        XCTAssertTrue(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .localWiFi, thirdPartyNeedsCleanup: false
        ).isEmpty)
    }

    func testConfiguredButUnusedRoundTripNeedsNoThirdPartyRequests() async {
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        defaults.set(true, forKey: "thirdPartyRuntimeModeInitialized")
        for destination in [ProxyRuntimeMode.localWiFi, .developerTunnel] {
            let needsCleanup = await manager.prepareForModeSwitch()
            XCTAssertTrue(RuntimeModeSwitchCleanup.required(
                from: .thirdParty, to: destination, thirdPartyNeedsCleanup: needsCleanup
            ).isEmpty)
        }
        XCTAssertTrue(requester.requestedURLs.isEmpty)
    }

    func testEmptyOrFailedInFlightQueryDoesNotRequireClear() async throws {
        for body in [#"{"success":false,"error":"无已保存的坐标"}"#, "not-json"] {
            let entered = expectation(description: "查询已发送")
            let requester = ControlledThirdPartyRequester(entered: entered, queryBody: body)
            let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
            let query = Task { try await manager.query() }
            await fulfillment(of: [entered], timeout: 2)
            let preparing = expectation(description: "切换等待已开始")
            let prepare = Task { preparing.fulfill(); return await manager.prepareForModeSwitch() }
            await fulfillment(of: [preparing], timeout: 2)
            XCTAssertFalse(manager.resumeWrites())
            await requester.release()
            do { _ = try await query.value; XCTFail("旧查询的 UI 结果应被取消") } catch is CancellationError {}
            let needsCleanup = await prepare.value
            XCTAssertFalse(needsCleanup)
            let actions = await requester.actions()
            XCTAssertEqual(actions, ["query"])
            XCTAssertEqual(manager.coordinateCleanupState, .none)
        }
    }

    func testConfirmedEmptyQueryClearsEarlierEvidence() async throws {
        let requester = FakeThirdPartyRequester(bodies: [
            #"{"success":true,"latitude":1,"longitude":1}"#,
            #"{"success":false,"error":"无已保存的坐标"}"#
        ])
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        _ = try await manager.query()
        XCTAssertTrue(manager.needsCoordinateCleanup())
        _ = try await manager.query()
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertFalse(restored.needsCoordinateCleanup())
    }

    func testFailedQueryDoesNotEraseRealEvidence() async throws {
        let requester = FakeThirdPartyRequester(bodies: [
            #"{"success":true,"latitude":1,"longitude":1}"#, "not-json"
        ])
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        _ = try await manager.query()
        do { _ = try await manager.query(); XCTFail("应报告查询失败") } catch {}
        XCTAssertEqual(manager.coordinateCleanupState, .possibleCoordinates)
    }

    func testLegacyFlagRemainsUnverifiedUntilUserConfirmsNeverUsed() async {
        defaults.set(true, forKey: "thirdPartyPendingCoordinateCleanup")
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertEqual(manager.coordinateCleanupState, .legacyUnverified)
        do { try await manager.clear(); XCTFail("应报告清理失败") } catch {}
        XCTAssertEqual(manager.coordinateCleanupState, .legacyUnverified)
        manager.confirmUnusedLegacyCleanup()
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertEqual(restored.coordinateCleanupState, .none)
        XCTAssertFalse(defaults.bool(forKey: "thirdPartyPendingCoordinateCleanup"))
        let needsCleanup = await restored.prepareForModeSwitch()
        XCTAssertFalse(needsCleanup)
        XCTAssertEqual(requester.requestedURLs.map(\.query), ["action=clear"])
    }

    func testOlderConfiguredInstallationWithoutCleanupKeysNeedsOneTimeReview() {
        defaults.set(true, forKey: "thirdPartyRuntimeModeInitialized")
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertEqual(manager.coordinateCleanupState, .legacyUnverified)
        manager.confirmUnusedLegacyCleanup()
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertEqual(restored.coordinateCleanupState, .none)
    }

    func testOldSuccessfulClearDoesNotRequireReviewDespiteInitialization() {
        defaults.set(true, forKey: "thirdPartyRuntimeModeInitialized")
        defaults.set(false, forKey: "thirdPartyPendingCoordinateCleanup")
        let manager = ThirdPartyProxyManager(requester: FakeThirdPartyRequester(body: "not-json"), defaults: defaults)
        XCTAssertEqual(manager.coordinateCleanupState, .none)
    }

    func testEmptyQueryResolvesLegacyFlagWithoutUserConfirmation() async throws {
        defaults.set(true, forKey: "thirdPartyPendingCoordinateCleanup")
        let manager = ThirdPartyProxyManager(
            requester: FakeThirdPartyRequester(body: #"{"success":false,"error":"无已保存的坐标"}"#),
            defaults: defaults
        )
        _ = try await manager.query()
        XCTAssertEqual(manager.coordinateCleanupState, .none)
    }

    func testLegacyConfirmationCannotEraseNewlyObservedCoordinates() async throws {
        defaults.set(true, forKey: "thirdPartyPendingCoordinateCleanup")
        let requester = FakeThirdPartyRequester(body: #"{"success":true,"latitude":1,"longitude":1}"#)
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        _ = try await manager.query()
        manager.confirmUnusedLegacyCleanup()
        XCTAssertEqual(manager.coordinateCleanupState, .possibleCoordinates)
        XCTAssertTrue(defaults.bool(forKey: "thirdPartyPendingCoordinateCleanup"))
    }

    func testLegacyConfirmationCannotEraseNewWriteWithUnknownResult() async {
        defaults.set(true, forKey: "thirdPartyPendingCoordinateCleanup")
        let manager = ThirdPartyProxyManager(requester: FakeThirdPartyRequester(body: "not-json"), defaults: defaults)
        let target = FavoriteLocation(name: "mock", latitude: 1, longitude: 1, accuracy: 5, mapCoordinateSystem: .wgs84)
        do { _ = try await manager.save(target); XCTFail("应报告回读失败") } catch {}
        manager.confirmUnusedLegacyCleanup()
        XCTAssertEqual(manager.coordinateCleanupState, .possibleCoordinates)
    }
}
