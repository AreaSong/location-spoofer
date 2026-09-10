import XCTest
@testable import PaopaoLocationSpoofer

final class ThirdPartyProxyDiagnosisTests: XCTestCase {
    func testCertificateURLErrorsMapToUntrusted() {
        let codes: [URLError.Code] = [
            .secureConnectionFailed,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired
        ]
        for code in codes {
            XCTAssertEqual(
                ThirdPartyProxyDiagnosis.fromTransport(URLError(code)),
                .certificateUntrusted,
                "URLError \(code.rawValue) should be a certificate failure"
            )
        }
    }

    func testCertificateKeywordInLocalizedDescriptionMapsToUntrusted() {
        let error = NSError(
            domain: "test.tls",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "证书未被信任"]
        )
        XCTAssertEqual(ThirdPartyProxyDiagnosis.fromTransport(error), .certificateUntrusted)
    }

    func testConnectivityURLErrorsMapToProxyNotConnected() {
        let codes: [URLError.Code] = [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .dataNotAllowed
        ]
        for code in codes {
            XCTAssertEqual(
                ThirdPartyProxyDiagnosis.fromTransport(URLError(code)),
                .proxyNotConnected,
                "URLError \(code.rawValue) should be a proxy connectivity failure"
            )
        }
    }

    func testUnknownTransportErrorKeepsNetworkMessage() {
        let error = NSError(
            domain: "test.other",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "临时中断"]
        )
        XCTAssertEqual(ThirdPartyProxyDiagnosis.fromTransport(error), .network("临时中断"))
    }

    func testUserFacingCopyNeverMentionsErrorCode() {
        let cases: [ThirdPartyProxyError] = [
            .certificateUntrusted,
            .proxyNotConnected,
            .moduleNotIntercepted,
            .rejected("模块拒绝了这次请求"),
            .coordinateMismatch,
            .invalidResponse,
            .network("临时中断")
        ]
        for item in cases {
            XCTAssertFalse(item.localizedDescription.contains("错误代码"))
            XCTAssertFalse(item.diagnosis.title.contains("错误代码"))
            XCTAssertFalse(item.diagnosis.summary.contains("错误代码"))
        }
    }

    func testOnDeviceHintOnlyAppearsWhenLocalServerIsDown() {
        let down = ThirdPartyProxyDiagnosis.moduleNotIntercepted.recoverySuggestion(
            usingOnDeviceModule: true,
            localServerRunning: false
        )
        let running = ThirdPartyProxyDiagnosis.moduleNotIntercepted.recoverySuggestion(
            usingOnDeviceModule: true,
            localServerRunning: true
        )
        let remote = ThirdPartyProxyDiagnosis.moduleNotIntercepted.recoverySuggestion(
            usingOnDeviceModule: false,
            localServerRunning: false
        )
        XCTAssertTrue(down.contains("本机模块服务未开"))
        XCTAssertFalse(running.contains("本机模块服务未开"))
        XCTAssertFalse(remote.contains("本机模块服务未开"))
    }

    func testCertificateAndProxySuggestionsStayActionable() {
        XCTAssertTrue(
            ThirdPartyProxyDiagnosis.certificateUntrusted
                .recoverySuggestion(usingOnDeviceModule: false, localServerRunning: true)
                .contains("完全信任")
        )
        XCTAssertTrue(
            ThirdPartyProxyDiagnosis.proxyNotConnected
                .recoverySuggestion(usingOnDeviceModule: false, localServerRunning: true)
                .contains("代理/VPN")
        )
    }
}
