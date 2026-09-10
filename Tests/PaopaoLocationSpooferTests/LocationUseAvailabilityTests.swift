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
            wifiEnabled: false,
            cellularEnabled: true,
            runtimeFailure: .thirdParty("模块没有拦住请求"),
            signing: signing
        )
        XCTAssertEqual(block, .signingExpired("免费签名已过期，请用电脑重新签名并安装。"))
        XCTAssertEqual(block?.message.contains("错误代码"), false)
    }

    func testAppModeWithoutWiFiBlocksAndIgnoresThirdPartyFailure() {
        let block = LocationUseAvailability.current(
            mode: .localWiFi,
            wifiEnabled: false,
            cellularEnabled: true,
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

    func testThirdPartyFailureOnlyAppliesInThirdPartyMode() {
        let failure = LocationRuntimeFailure.thirdParty("模块没有拦住请求")
        XCTAssertEqual(
            LocationUseAvailability.current(
                mode: .thirdParty,
                wifiEnabled: false,
                cellularEnabled: true,
                runtimeFailure: failure,
                signing: .unknownStatus
            ),
            .thirdParty("模块没有拦住请求")
        )
        XCTAssertNil(
            LocationUseAvailability.current(
                mode: .localWiFi,
                wifiEnabled: true,
                cellularEnabled: false,
                runtimeFailure: failure,
                signing: .unknownStatus
            )
        )
    }

    func testAvailableWhenWiFiAndNoRuntimeFailure() {
        XCTAssertNil(
            LocationUseAvailability.current(
                mode: .localWiFi,
                wifiEnabled: true,
                cellularEnabled: false,
                runtimeFailure: nil,
                signing: .unknownStatus
            )
        )
    }
}

private extension SigningExpiryStatus {
    static var unknownStatus: SigningExpiryStatus {
        SigningExpiryStatus(kind: .unknown, expirationDate: nil)
    }
}
