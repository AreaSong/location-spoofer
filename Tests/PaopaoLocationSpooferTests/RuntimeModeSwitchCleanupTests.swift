import XCTest
@testable import PaopaoLocationSpoofer

final class RuntimeModeSwitchCleanupTests: XCTestCase {
    func testUnusedThirdPartyCanReturnToDeveloperTunnelWithoutClear() {
        XCTAssertTrue(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .developerTunnel, thirdPartyNeedsCleanup: false
        ).isEmpty)
        XCTAssertTrue(RuntimeModeSwitchCleanup.mustSucceed(
            from: .thirdParty, to: .developerTunnel, thirdPartyNeedsCleanup: false
        ).isEmpty)
    }

    func testAppModeDoesNotRequireClearWhenThirdPartyWasUnused() {
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .localWiFi, thirdPartyNeedsCleanup: false
        ), [])
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .developerTunnel, to: .localWiFi, thirdPartyNeedsCleanup: false
        ), [.developerSimulation])
    }

    func testLeavingThirdPartyClearsSavedWLOC() {
        XCTAssertEqual(
            RuntimeModeSwitchCleanup.required(from: .thirdParty, to: .developerTunnel),
            [.thirdPartyWLOC]
        )
        XCTAssertEqual(
            RuntimeModeSwitchCleanup.required(from: .thirdParty, to: .localWiFi),
            [.thirdPartyWLOC]
        )
    }

    func testLeavingDeveloperTunnelClearsSystemSimulation() {
        XCTAssertEqual(
            RuntimeModeSwitchCleanup.required(from: .developerTunnel, to: .thirdParty),
            [.developerSimulation]
        )
        XCTAssertEqual(
            RuntimeModeSwitchCleanup.required(from: .developerTunnel, to: .localWiFi),
            [.developerSimulation, .thirdPartyWLOC]
        )
    }

    func testAppModeToDeveloperTunnelDoesNotRequireThirdPartyClear() {
        XCTAssertTrue(
            RuntimeModeSwitchCleanup.required(from: .localWiFi, to: .developerTunnel, thirdPartyNeedsCleanup: false).isEmpty
        )
    }

    func testKnownCoordinatesStillRequireCleanupBetweenAppAndDeveloperModes() {
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .localWiFi, to: .developerTunnel, thirdPartyNeedsCleanup: true
        ), [.thirdPartyWLOC])
    }

    func testSameModeRequiresNothing() {
        XCTAssertTrue(
            RuntimeModeSwitchCleanup.required(from: .thirdParty, to: .thirdParty).isEmpty
        )
    }

    func testLeavingThirdPartyToDeveloperTunnelRequiresClear() {
        XCTAssertEqual(
            RuntimeModeSwitchCleanup.mustSucceed(from: .thirdParty, to: .developerTunnel),
            [.thirdPartyWLOC]
        )
    }

    func testLeavingThirdPartyToAppModeWLOCMustSucceed() {
        XCTAssertEqual(
            RuntimeModeSwitchCleanup.mustSucceed(from: .thirdParty, to: .localWiFi),
            [.thirdPartyWLOC]
        )
    }

    func testUserConfirmedDisabledThirdPartyCanLeaveForEitherMode() {
        for destination in [ProxyRuntimeMode.localWiFi, .developerTunnel] {
            let recovery = ThirdPartyModeSwitchRecovery(
                source: .thirdParty, destination: destination, diagnosis: "模块未接管请求"
            )
            XCTAssertTrue(RuntimeModeSwitchCleanup.required(
                from: .thirdParty, to: destination, confirmedThirdPartyDisabled: recovery
            ).isEmpty)
        }
    }

    func testConfirmationCannotBypassDeveloperSimulationClear() {
        let recovery = ThirdPartyModeSwitchRecovery(
            source: .developerTunnel, destination: .localWiFi, diagnosis: "模块未接管请求"
        )
        XCTAssertEqual(RuntimeModeSwitchCleanup.mustSucceed(
            from: .developerTunnel, to: .localWiFi, confirmedThirdPartyDisabled: recovery
        ), [.developerSimulation])
    }

    func testConfirmationDoesNotApplyToDifferentSourceOrDestination() {
        let recovery = ThirdPartyModeSwitchRecovery(
            source: .thirdParty, destination: .developerTunnel, diagnosis: "模块未接管请求"
        )
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .localWiFi, confirmedThirdPartyDisabled: recovery
        ), [.thirdPartyWLOC])
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .developerTunnel, to: .localWiFi, confirmedThirdPartyDisabled: recovery
        ), [.developerSimulation, .thirdPartyWLOC])
        XCTAssertFalse(recovery.applies(from: .localWiFi, to: .developerTunnel))
    }
}
