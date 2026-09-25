import XCTest
@testable import PaopaoLocationSpoofer

final class RuntimeModeSwitchCleanupTests: XCTestCase {
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
}
