import XCTest
@testable import PaopaoLocationSpoofer

final class LocationNetworkSpoofRefreshTests: XCTestCase {
    func testRestartIsRequiredFromIOS26() {
        XCTAssertFalse(LocationNetworkSpoofRefresh.requiresDeviceRestart(iOSMajor: 18))
        XCTAssertTrue(LocationNetworkSpoofRefresh.requiresDeviceRestart(iOSMajor: 26))
        XCTAssertTrue(LocationNetworkSpoofRefresh.requiresDeviceRestart(iOSMajor: 27))
    }

    func testSetupWarningExplainsCacheOnIOS26AndMITMOnIOS27() {
        XCTAssertNil(LocationNetworkSpoofRefresh.setupWarning(iOSMajor: 18))
        XCTAssertEqual(
            LocationNetworkSpoofRefresh.setupWarning(iOSMajor: 26),
            LocationNetworkSpoofRefresh.cacheRestartMessage
        )
        XCTAssertTrue(
            LocationNetworkSpoofRefresh.setupWarning(iOSMajor: 27)?.contains("MITM") == true
        )
    }
}
