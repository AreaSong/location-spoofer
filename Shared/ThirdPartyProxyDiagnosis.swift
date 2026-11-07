import Foundation

enum ThirdPartyProxyDiagnosis: Equatable {
    case certificateUntrusted
    case proxyNotConnected
    case moduleNotIntercepted
    case rejected(String)
    case coordinateMismatch
    case invalidResponse
    case network(String)

    var title: String {
        switch self {
        case .certificateUntrusted:
            return "HTTPS 证书校验失败"
        case .proxyNotConnected:
            return "代理未连上"
        case .moduleNotIntercepted:
            return "模块没有拦住请求"
        case .rejected:
            return "模块拒绝了这次请求"
        case .coordinateMismatch:
            return "保存的坐标不一致"
        case .invalidResponse:
            return "返回了无法识别的数据"
        case .network:
            return "网络请求失败"
        }
    }

    var summary: String {
        switch self {
        case .certificateUntrusted:
            return "HTTPS 证书校验失败。即使已开启完全信任，证书链、域名或有效期等校验仍可能失败。请查看运行日志中的证书校验诊断。"
        case .proxyNotConnected:
            return "连不上控制接口。请更新定位模块、开启代理/VPN；小火箭使用「配置」路由，并保持本 App 运行供本机脚本下载。"
        case .moduleNotIntercepted:
            return "未收到新版定位模块的有效响应。请更新并启用定位模块，开启 HTTPS 解密并添加独立控制域名；独立探测模块不能替代定位模块。"
        case .rejected(let message):
            return message
        case .coordinateMismatch:
            return "第三方代理保存的坐标与当前选点不一致"
        case .invalidResponse:
            return "第三方代理返回了无法识别的数据"
        case .network(let message):
            return "第三方代理请求失败：\(message)"
        }
    }

    func recoverySuggestion(usingOnDeviceModule: Bool, localServerRunning: Bool) -> String {
        switch self {
        case .certificateUntrusted:
            return "确认当前代理的 HTTPS 解密证书已安装并开启完全信任；若已信任，请复制运行日志中的证书校验诊断，不要忽略证书警告"
        case .proxyNotConnected:
            return "打开代理客户端并开启代理/VPN 连接，确认状态栏出现 VPN 后再检测"
        case .moduleNotIntercepted:
            var suggestion = "更新并启用定位模块，开启 HTTPS 解密并添加 location-spoofer.invalid；小火箭使用「配置」路由"
            if usingOnDeviceModule && !localServerRunning {
                suggestion += "。本机模块服务未开，若刚导入或点了更新，请先打开本 App 再导入"
            }
            return suggestion
        case .rejected, .coordinateMismatch, .invalidResponse, .network:
            return "检查模块、MITM、证书和代理/VPN 连接"
        }
    }

    static func fromTransport(_ error: Error) -> ThirdPartyProxyDiagnosis {
        let nsError = error as NSError
        if Self.isCertificateTrustError(nsError) {
            return .certificateUntrusted
        }
        if Self.isProxyOrConnectivityError(nsError) {
            return .proxyNotConnected
        }
        return .network(error.localizedDescription)
    }

    static func isCertificateTrustError(_ nsError: NSError) -> Bool {
        if nsError.domain == NSURLErrorDomain {
            let codes: Set<Int> = [-1201, -1202, -1203, -1204, -1205, -1206]
            return codes.contains(nsError.code)
        }
        let normalized = nsError.localizedDescription.lowercased()
        return normalized.contains("certificate")
            || normalized.contains("证书")
    }

    static func isProxyOrConnectivityError(_ nsError: NSError) -> Bool {
        guard nsError.domain == NSURLErrorDomain else { return false }
        let codes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDataNotAllowed
        ]
        return codes.contains(nsError.code)
    }
}
