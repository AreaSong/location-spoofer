import XCTest
@testable import PaopaoLocationSpoofer

final class LocationNetworkSpoofRefreshTests: XCTestCase {
    func testStrongerCacheStartsAtIOS26() {
        XCTAssertFalse(LocationNetworkSpoofRefresh.hasStrongerLocationCache(iOSMajor: 18))
        XCTAssertTrue(LocationNetworkSpoofRefresh.hasStrongerLocationCache(iOSMajor: 26))
        XCTAssertTrue(LocationNetworkSpoofRefresh.hasStrongerLocationCache(iOSMajor: 27))
    }

    func testSetupWarningPrefersLocationToggleThenRebootOnIOS26() {
        XCTAssertNil(LocationNetworkSpoofRefresh.setupWarning(iOSMajor: 18))
        XCTAssertEqual(
            LocationNetworkSpoofRefresh.setupWarning(iOSMajor: 26),
            LocationNetworkSpoofRefresh.cacheRefreshMessage
        )
        XCTAssertTrue(LocationNetworkSpoofRefresh.cacheRefreshMessage.contains("定位服务"))
        let ios27 = LocationNetworkSpoofRefresh.setupWarning(iOSMajor: 27)
        XCTAssertTrue(ios27?.contains("MITM") == true)
        XCTAssertTrue(ios27?.contains("开发者隧道") == true)
        XCTAssertFalse(ios27?.contains("等待后续适配") == true)
    }
}
