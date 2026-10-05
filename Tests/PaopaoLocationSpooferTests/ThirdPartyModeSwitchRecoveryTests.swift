import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyModeSwitchRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let suite = "ThirdPartyModeSwitchRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    }

    func testUninterceptedClearCanBeExplicitlySkippedWithoutLosingPendingRecord() async {
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        do { try await manager.clear(); XCTFail("未拦截的清理必须失败") }
        catch { XCTAssertEqual(error as? ThirdPartyProxyError, .moduleNotIntercepted) }

        for destination in [ProxyRuntimeMode.localWiFi, .developerTunnel] {
            let recovery = ThirdPartyModeSwitchRecovery(
                source: .thirdParty, destination: destination,
                diagnosis: ThirdPartyProxyError.moduleNotIntercepted.diagnosis.summary
            )
            XCTAssertTrue(RuntimeModeSwitchCleanup.required(
                from: .thirdParty, to: destination, confirmedThirdPartyDisabled: recovery
            ).isEmpty)
            XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
            XCTAssertTrue(recovery.message.contains(destination.displayName))
            XCTAssertTrue(recovery.message.contains("第三方坐标尚未清除"))
        }
        XCTAssertEqual(requester.requestedURLs.map(\.query), ["action=clear"])
        let restored = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        XCTAssertTrue(restored.needsCoordinateCleanup(hasInitializedThirdParty: false))
        // 这次确认不成为后续切换的永久豁免。
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(from: .thirdParty, to: .developerTunnel), [.thirdPartyWLOC])
    }

    func testRetryStillSendsClearAndOnlySuccessRemovesPendingRecord() async throws {
        let requester = FakeThirdPartyRequester(bodies: ["not-json", #"{"success":true}"#])
        let manager = ThirdPartyProxyManager(requester: requester, defaults: defaults)
        do { try await manager.clear(); XCTFail("首次应失败") } catch is ThirdPartyProxyError {}
        XCTAssertTrue(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(from: .thirdParty, to: .localWiFi), [.thirdPartyWLOC])

        try await manager.clear()

        XCTAssertEqual(requester.requestedURLs.map(\.query), ["action=clear", "action=clear"])
        XCTAssertFalse(manager.needsCoordinateCleanup(hasInitializedThirdParty: false))
    }
}
