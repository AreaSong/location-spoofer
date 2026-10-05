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

    func testAppModeStillRequiresClearEvenWhenThirdPartyWasUnused() {
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .thirdParty, to: .localWiFi, thirdPartyNeedsCleanup: false
        ), [.thirdPartyWLOC])
        XCTAssertEqual(RuntimeModeSwitchCleanup.required(
            from: .developerTunnel, to: .localWiFi, thirdPartyNeedsCleanup: false
        ), [.developerSimulation, .thirdPartyWLOC])
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
            RuntimeModeSwitchCleanup.required(from: .localWiFi, to: .developerTunnel).isEmpty
        )
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
}
