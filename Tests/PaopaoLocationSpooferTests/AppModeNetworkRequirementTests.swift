import XCTest
@testable import PaopaoLocationSpoofer

final class AppModeNetworkRequirementTests: XCTestCase {
    func testWiFiAllowsAppMode() {
        XCTAssertTrue(AppModeNetworkRequirement.canUseAppMode(wifiEnabled: true))
        XCTAssertNil(
            AppModeNetworkRequirement.blockedMessage(wifiEnabled: true, cellularEnabled: true)
        )
        XCTAssertNil(
            AppModeNetworkRequirement.blockedMessage(wifiEnabled: true, cellularEnabled: false)
        )
    }

    func testCellularOnlyBlocksAppMode() {
        XCTAssertFalse(AppModeNetworkRequirement.canUseAppMode(wifiEnabled: false))
        let message = AppModeNetworkRequirement.blockedMessage(
            wifiEnabled: false,
            cellularEnabled: true
        )
        XCTAssertEqual(
            message,
            "当前是蜂窝网络。APP 模式只支持 Wi-Fi，请改用第三方代理模式，并保持小火箭开启。"
        )
    }

    func testNoNetworkBlocksAppMode() {
        let message = AppModeNetworkRequirement.blockedMessage(
            wifiEnabled: false,
            cellularEnabled: false
        )
        XCTAssertEqual(
            message,
            "当前未连接 Wi-Fi。APP 模式需要 Wi-Fi；只有流量时请改用第三方代理模式并保持小火箭开启。"
        )
    }
}
