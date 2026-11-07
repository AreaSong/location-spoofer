import Foundation

/// 独立探测不复用定位管理器，避免影响坐标、连接状态或运行失败状态。
enum IndependentHTTPSProbe {
    static let endpoint = URL(string: "https://location-spoofer.invalid/probe")!
    static let moduleFileName = "wloc-probe.module"
    static let successMessage = "独立 HTTPS 探测通过；仅证明固定响应可达，不代表定位已生效。"

    @MainActor
    static func run(requester: (any ThirdPartyProxyRequesting)? = nil) async -> String {
        let session = ThirdPartyControlTransport.session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await (requester ?? session).data(for: request)
            try Task.checkCancellation()
            guard accepts(data: data, response: response) else {
                let message = "独立 HTTPS 探测失败：未收到预期固定响应。请确认已导入并启用小火箭探测模块。"
                RuntimeLogger.warning("APP", "HTTPSProbe", message)
                return message
            }
            RuntimeLogger.info("APP", "HTTPSProbe", successMessage)
            return successMessage
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                return "独立 HTTPS 探测已取消"
            }
            let id = UUID().uuidString
            RuntimeLogger.error("APP", "HTTPSProbe", "独立 HTTPS 探测失败", error: error, details: ["诊断ID": id])
            if ThirdPartyProxyDiagnosis.isCertificateTrustError(error as NSError) {
                ThirdPartyTrustDiagnostics.record(error: error, requestID: id)
            }
            return "独立 HTTPS 探测失败：\(error.localizedDescription)"
        }
    }

    static func accepts(data: Data, response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200, http.url == endpoint, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return object == ["protocol": "location-spoofer-probe", "version": "1", "mode": "no-storage"]
    }
}
