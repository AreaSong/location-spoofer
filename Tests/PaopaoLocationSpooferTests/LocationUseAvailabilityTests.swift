import XCTest
@testable import PaopaoLocationSpoofer

final class LocationUseAvailabilityTests: XCTestCase {
    func testExpiredSigningBlocksBeforeOtherReasons() {
        let signing = SigningExpiry.evaluate(
            expirationDate: Date(timeIntervalSince1970: 1),
            now: Date(timeIntervalSince1970: 2)
        )
        let block = LocationUseAvailability.current(
            mode: .localWiFi,
            network: .cellularOnly,
            runtimeFailure: .thirdParty("模块没有拦住请求"),
            signing: signing
        )
        XCTAssertEqual(block, .signingExpired("免费签名已过期，请用电脑重新签名并安装。"))
        XCTAssertEqual(block?.message.contains("错误代码"), false)
    }

    func testAppModeWithoutWiFiBlocksAndIgnoresThirdPartyFailure() {
        let block = LocationUseAvailability.current(
            mode: .localWiFi,
            network: .cellularOnly,
            runtimeFailure: .thirdParty("模块没有拦住请求"),
            signing: .unknownStatus
        )
        XCTAssertEqual(
            block,
            .appModeNeedsWiFi(
                "当前是蜂窝网络。APP 模式只支持 Wi-Fi，请改用第三方代理模式，并保持小火箭开启。"
            )
        )
    }

    func testAppModeBlocksWhenWiFiInterfaceExistsButPathIsUnsatisfied() {
        let block = LocationUseAvailability.current(
            mode: .localWiFi,
            network: AppModeNetworkStatus(pathSatisfied: false, wifiEnabled: true, cellularEnabled: false),
            runtimeFailure: nil,
            signing: .unknownStatus
        )
        XCTAssertEqual(
            block,
            .appModeNeedsWiFi(
                "当前 Wi-Fi 网络不可用。APP 模式需要可用的 Wi-Fi；没有网络时请改用第三方代理模式并保持小火箭开启。"
            )
        )
    }

    func testThirdPartyFailureOnlyAppliesInThirdPartyMode() {
        let failure = LocationRuntimeFailure.thirdParty("模块没有拦住请求")
        XCTAssertEqual(
            LocationUseAvailability.current(
                mode: .thirdParty,
                network: .cellularOnly,
                runtimeFailure: failure,
                signing: .unknownStatus
            ),
            .thirdParty("模块没有拦住请求")
        )
        XCTAssertNil(
            LocationUseAvailability.current(
                mode: .localWiFi,
                network: .satisfiedWiFi,
                runtimeFailure: failure,
                signing: .unknownStatus
            )
        )
    }

    func testAvailableWhenWiFiAndNoRuntimeFailure() {
        XCTAssertNil(
            LocationUseAvailability.current(
                mode: .localWiFi,
                network: .satisfiedWiFi,
                runtimeFailure: nil,
                signing: .unknownStatus
            )
        )
    }
}

private extension AppModeNetworkStatus {
    static let cellularOnly = AppModeNetworkStatus(
        pathSatisfied: true,
        wifiEnabled: false,
        cellularEnabled: true
    )
    static let satisfiedWiFi = AppModeNetworkStatus(
        pathSatisfied: true,
        wifiEnabled: true,
        cellularEnabled: false
    )
}

private extension SigningExpiryStatus {
    static var unknownStatus: SigningExpiryStatus {
        SigningExpiryStatus(kind: .unknown, expirationDate: nil)
    }
}
