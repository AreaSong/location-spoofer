import Foundation

/// 控制接口与探测共用传输边界：系统校验证书，不携带会话凭据，不跟随重定向。
enum ThirdPartyControlTransport {
    static let host = "location-spoofer.invalid"
    static let protocolHeader = "X-Wloc-Control"
    static let protocolVersion = "1"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: ThirdPartyRedirectBlocker(), delegateQueue: nil)
    }

    static func safeErrorDetails(_ error: Error) -> [String: String] {
        let value = error as NSError
        // URL 错误的 userInfo 和自定义描述可能包含带坐标的失败地址；只记录稳定错误域和代码。
        return ["error.domain": value.domain, "error.code": String(value.code)]
    }
}

final class ThirdPartyRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
