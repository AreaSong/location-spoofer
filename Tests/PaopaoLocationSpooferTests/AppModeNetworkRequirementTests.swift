import XCTest
@testable import PaopaoLocationSpoofer

final class AppModeNetworkRequirementTests: XCTestCase {
    func testSatisfiedWiFiAllowsAppMode() {
        let wifi = AppModeNetworkStatus(pathSatisfied: true, wifiEnabled: true, cellularEnabled: false)
        let wifiAndCellular = AppModeNetworkStatus(pathSatisfied: true, wifiEnabled: true, cellularEnabled: true)
        XCTAssertTrue(AppModeNetworkRequirement.canUseAppMode(wifi))
        XCTAssertNil(AppModeNetworkRequirement.blockedMessage(wifi))
        XCTAssertNil(AppModeNetworkRequirement.blockedMessage(wifiAndCellular))
    }

    func testWiFiInterfaceWithoutSatisfiedPathBlocksAppMode() {
        let status = AppModeNetworkStatus(pathSatisfied: false, wifiEnabled: true, cellularEnabled: true)
        XCTAssertFalse(AppModeNetworkRequirement.canUseAppMode(status))
        XCTAssertEqual(
            AppModeNetworkRequirement.blockedMessage(status),
            "当前 Wi-Fi 网络不可用。APP 模式需要可用的 Wi-Fi；没有网络时请改用第三方代理模式并保持小火箭开启。"
        )
    }

    func testCellularOnlyBlocksAppMode() {
        let status = AppModeNetworkStatus(pathSatisfied: true, wifiEnabled: false, cellularEnabled: true)
        XCTAssertFalse(AppModeNetworkRequirement.canUseAppMode(status))
        XCTAssertEqual(
            AppModeNetworkRequirement.blockedMessage(status),
            "当前是蜂窝网络。APP 模式只支持 Wi-Fi，请改用第三方代理模式，并保持小火箭开启。"
        )
    }

    func testNoNetworkBlocksAppMode() {
        let status = AppModeNetworkStatus(pathSatisfied: false, wifiEnabled: false, cellularEnabled: false)
        XCTAssertEqual(
            AppModeNetworkRequirement.blockedMessage(status),
            "当前未连接 Wi-Fi。APP 模式需要 Wi-Fi；只有流量时请改用第三方代理模式并保持小火箭开启。"
        )
    }
}
