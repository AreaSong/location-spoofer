import CryptoKit
import Foundation
import Security

enum ThirdPartyTrustDiagnostics {
    // 仅观察失败请求携带的信任对象；不设置锚点、例外、策略或挑战回调。
    static func record(error: Error, requestID: String) {
        Task.detached(priority: .utility) {
            let details = details(for: error).merging(["诊断ID": requestID]) { _, new in new }
            RuntimeLogger.error("APP", "ThirdPartyProxy", "证书校验诊断", details: details)
        }
    }

    static func details(for error: Error) -> [String: String] {
        guard let trust = trustObject(in: error as NSError) else {
            return ["trust.status": "错误未携带 SecTrust，无法取得详细校验原因"]
        }
        // 用原对象及其原有策略取得详细错误。系统可能重新评估或联网，因此只在后台调用。
        var evaluationError: CFError?
        let valid = SecTrustEvaluateWithError(trust, &evaluationError)
        var values = [
            "trust.evaluationSucceeded": String(valid),
            "trust.source": "诊断时评估原请求信任对象；不替代原请求结果"
        ]
        if let evaluationError {
            appendErrors(evaluationError as Error as NSError, to: &values)
        }
        if valid {
            values["trust.status"] = "诊断时校验通过，原请求仍按失败处理；请核对信任状态是否变化"
        }
        let result = SecTrustCopyResult(trust) as? [String: Any] ?? [:]
        for key in [kSecTrustResultValue, kSecTrustEvaluationDate] {
            if let value = result[key as String] {
                values["trust.\(key)"] = String(describing: value)
            }
        }
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        values["trust.chainCount"] = String(chain.count)
        for (index, certificate) in chain.prefix(16).enumerated() {
            let prefix = "trust.certificate.\(index)"
            values["\(prefix).subject"] = SecCertificateCopySubjectSummary(certificate) as String?
            let data = SecCertificateCopyData(certificate) as Data
            values["\(prefix).sha256"] = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            if #available(iOS 18.0, macOS 15.0, *) {
                values["\(prefix).notBefore"] = dateText(SecCertificateCopyNotValidBeforeDate(certificate))
                values["\(prefix).notAfter"] = dateText(SecCertificateCopyNotValidAfterDate(certificate))
            }
        }
        return values
    }

    private static func dateText(_ date: CFDate?) -> String? {
        guard let date else { return nil }
        return ISO8601DateFormatter().string(from: date as Date)
    }

    private static func trustObject(in error: NSError) -> SecTrust? {
        var current: NSError? = error
        for _ in 0..<8 {
            guard let entry = current else { break }
            if let value = entry.userInfo[NSURLErrorFailingURLPeerTrustErrorKey],
               CFGetTypeID(value as CFTypeRef) == SecTrustGetTypeID() {
                return (value as! SecTrust)
            }
            current = entry.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    private static func appendErrors(_ error: NSError, to values: inout [String: String]) {
        var current: NSError? = error
        for depth in 0..<8 {
            guard let entry = current else { break }
            let prefix = "trust.error.\(depth)"
            values["\(prefix).domain"] = entry.domain
            values["\(prefix).code"] = String(entry.code)
            values["\(prefix).description"] = String(entry.localizedDescription.prefix(4096))
            current = entry.userInfo[NSUnderlyingErrorKey] as? NSError
        }
    }
}
