import XCTest
@testable import PaopaoLocationSpoofer

final class RuntimeModeAvailabilityTests: XCTestCase {
    func testIOS27RecommendsTunnelAndLimitsInterceptionModes() {
        XCTAssertEqual(RuntimeModeAvailability.status(for: .developerTunnel, iOSMajor: 27), .recommended)
        XCTAssertEqual(
            RuntimeModeAvailability.status(for: .localWiFi, iOSMajor: 27),
            .limited(RuntimeModeAvailability.mitmBlockedReason)
        )
        XCTAssertEqual(
            RuntimeModeAvailability.status(for: .thirdParty, iOSMajor: 28),
            .limited(RuntimeModeAvailability.mitmBlockedReason)
        )
    }

    func testIOS18To26RecommendsTunnelAndKeepsOthersAvailable() {
        for major in [18, 22, 26] {
            XCTAssertEqual(RuntimeModeAvailability.status(for: .developerTunnel, iOSMajor: major), .recommended)
            XCTAssertEqual(RuntimeModeAvailability.status(for: .localWiFi, iOSMajor: major), .available)
            XCTAssertEqual(RuntimeModeAvailability.status(for: .thirdParty, iOSMajor: major), .available)
        }
    }

    func testBelowIOS18MakesTunnelUnavailable() {
        XCTAssertEqual(
            RuntimeModeAvailability.status(for: .developerTunnel, iOSMajor: 17),
            .unavailable(RuntimeModeAvailability.tunnelUnavailableReason)
        )
        XCTAssertEqual(RuntimeModeAvailability.status(for: .localWiFi, iOSMajor: 15), .available)
        XCTAssertEqual(RuntimeModeAvailability.status(for: .thirdParty, iOSMajor: 15), .available)
    }

    func testOrderingPutsRecommendedFirstAndUnavailableLast() {
        XCTAssertEqual(
            RuntimeModeAvailability.orderedModes(iOSMajor: 18),
            [.developerTunnel, .localWiFi, .thirdParty]
        )
        XCTAssertEqual(
            RuntimeModeAvailability.orderedModes(iOSMajor: 27),
            [.developerTunnel, .localWiFi, .thirdParty]
        )
        XCTAssertEqual(
            RuntimeModeAvailability.orderedModes(iOSMajor: 17),
            [.localWiFi, .thirdParty, .developerTunnel]
        )
        XCTAssertEqual(Set(RuntimeModeAvailability.orderedModes(iOSMajor: 17)), Set(ProxyRuntimeMode.allCases))
    }
}
