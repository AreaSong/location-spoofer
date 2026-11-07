import Foundation
import Security
import XCTest
@testable import PaopaoLocationSpoofer

final class ThirdPartyTrustDiagnosticsTests: XCTestCase {
    func testMissingOrMalformedTrustDoesNotCrashOrCopyPrivateMetadata() {
        for value: Any in ["not-a-trust", 123] {
            let error = NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [
                NSURLErrorFailingURLPeerTrustErrorKey: value,
                "private": "coordinate-secret"
            ])
            let details = ThirdPartyTrustDiagnostics.details(for: error)
            XCTAssertTrue(details["trust.status"]?.contains("未携带") == true)
            XCTAssertFalse(String(describing: details).contains("coordinate-secret"))
        }
        XCTAssertNotNil(ThirdPartyTrustDiagnostics.details(for: URLError(.timedOut))["trust.status"])
    }

    func testUnevaluatedTrustStillReportsDiagnosticEvaluationAsSeparateEvidence() throws {
        let trust = try makeTrust()
        let details = ThirdPartyTrustDiagnostics.details(for: transportError(trust))
        XCTAssertEqual(details["trust.evaluationSucceeded"], "false")
        XCTAssertTrue(details["trust.source"]?.contains("不替代原请求结果") == true)
    }

    func testRejectedCertificateReportsReasonAndFingerprintWithoutChangingTrust() throws {
        let trust = try makeTrust()
        var before: CFError?
        XCTAssertFalse(SecTrustEvaluateWithError(trust, &before))
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [
            NSUnderlyingErrorKey: transportError(trust)
        ])
        let details = ThirdPartyTrustDiagnostics.details(for: wrapped)
        XCTAssertEqual(details["trust.evaluationSucceeded"], "false")
        XCTAssertNotNil(details["trust.error.0.code"])
        XCTAssertFalse(try XCTUnwrap(details["trust.error.0.description"]).isEmpty)
        XCTAssertEqual(details["trust.chainCount"], "1")
        XCTAssertEqual(details["trust.certificate.0.subject"], "diagnostic.invalid")
        XCTAssertEqual(details["trust.certificate.0.sha256"], "7b887e4433dd2af3892eac40a85f064c7f9fbb899ca44f265c4c10ab314f33b3")
        if #available(iOS 18.0, *) {
            XCTAssertNotNil(details["trust.certificate.0.notBefore"])
            XCTAssertNotNil(details["trust.certificate.0.notAfter"])
        }
        var after: CFError?
        XCTAssertFalse(SecTrustEvaluateWithError(trust, &after))
        XCTAssertEqual(before.map(CFErrorGetCode), after.map(CFErrorGetCode))
    }

    func testSuccessfulDiagnosticDoesNotHideOriginalFailure() throws {
        let trust = try makeTrust()
        let data = try XCTUnwrap(Data(base64Encoded: Self.certificate))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        XCTAssertEqual(SecTrustSetAnchorCertificates(trust, [certificate] as CFArray), errSecSuccess)
        let verificationDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z"))
        SecTrustSetVerifyDate(trust, verificationDate as CFDate)
        let details = ThirdPartyTrustDiagnostics.details(for: transportError(trust))
        XCTAssertEqual(details["trust.evaluationSucceeded"], "true")
        XCTAssertTrue(details["trust.status"]?.contains("原请求仍按失败处理") == true)
        XCTAssertNil(details["trust.error.0.code"])
    }

    private func transportError(_ trust: SecTrust) -> NSError {
        NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [
            NSURLErrorFailingURLPeerTrustErrorKey: trust
        ])
    }

    private func makeTrust() throws -> SecTrust {
        // 仅包含合成自签公钥证书；不安装到系统信任库，不保存私钥。
        let data = try XCTUnwrap(Data(base64Encoded: Self.certificate))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(
            certificate, SecPolicyCreateSSL(true, "diagnostic.invalid" as CFString), &trust
        ), errSecSuccess)
        let result = try XCTUnwrap(trust)
        SecTrustSetNetworkFetchAllowed(result, false)
        return result
    }

    private static let certificate = "MIIEADCCAmigAwIBAgIJAOJac0G5kkhXMA0GCSqGSIb3DQEBCwUAMB0xGzAZBgNVBAMMEmRpYWdub3N0aWMuaW52YWxpZDAeFw0yNjExMDcwNDIxMzZaFw0yNjExMDgwNDIxMzZaMB0xGzAZBgNVBAMMEmRpYWdub3N0aWMuaW52YWxpZDCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBALGP7S+6nebjxALTBbCB7O6SM+hEi1+2S6fk/2gVP7xcJxXtkb2qXpOXeFMo7id2gnZvm6X0peiWTIVBBVkJIh5rpAJ1BIulXuNJCA2UMRVoAPUYCE4hhNQvT2EzzsLNtico+mLoL3x9CM0PdyhrYSBQQl5UwjemMjicd/2kA8pL9hRsor3BRxoFEl34KruVqo/bsgarkhz1UAPQler/1tK3exkLKG6w55hNI3m9yHwWA6jQLO5itEgqSMX7+O5dQroYMVVt8y/CoRoyYFTINE1z2PyVRVaWYlTvKEJ+vcQNUY4JSKQEttOhSmjMuihba3LoyHyjar/sjv2ix7PxDEat/4c0Xd7NIUPWcT//ayDjkYtF2QlQr4c+dclVnghwMuOlG/HaF/MCF9atcFX8F4j3P4SBASn5i7TkfK5crLXSMcFlTUsCJWRCcix8cm6MjJin8zAQHg0ybUKS1sLVQcL/Lq+3+J8R3Tq+K1PnTKVCy3UyOqekD3S8dA9xZ6yMtwIDAQABo0MwQTAdBgNVHREEFjAUghJkaWFnbm9zdGljLmludmFsaWQwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCwYDVR0PBAQDAgeAMA0GCSqGSIb3DQEBCwUAA4IBgQAAxAQ4pMtoQgmHUUOXRda3gy4/f8Vqwn4+zzUKxEJIUqynTGDf5zD15DHtyDSflaLkssMyAA64M044LBmZfKnark40yGChYVITneyJWRPV5MjkmwEF3pTTMBlnz41l9Vo5ddATAF4hG31p1xSvVjRwWXTf+bhSz0L1cHfZezwfr1uAbKK0NNdVzaMPduf6Pc4x+iVdLfe7HV+IccUxdcqUDS7WWzTxjTnWA7CVHEdhpso1Jy7OsQ7HJmBtb+JQLoNk803P1Cs1Tl+SNNh3HVsAonCL9zNdcIwcFBXGwmiaCNj+qetxn4hKI8nj98/Wr5edE0FsLV16Zm1sbuYYOw43xQ9qkXOwIE++iorn2s2PNdJJsDUYKctjA8ubJj/mFX8dYA0Mvw79ISLHcr92MqPpXm+9AsIKxqs2rnVv7wo29ye3r/beXzYQkiBMZx/zgSTD6tK51C9xJIj+kvIB9OH/7w2NqJSASSXdi32rzlAgmGJ1XM0i0RU6seQeXu50br4="
}
