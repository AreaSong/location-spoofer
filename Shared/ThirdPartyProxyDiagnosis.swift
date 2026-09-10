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
            return "证书未完全信任"
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
            return "证书未完全信任。请在代理客户端完成 HTTPS 解密证书安装，并在系统设置里打开完全信任。"
        case .proxyNotConnected:
            return "连不上定位接口。请确认第三方代理/VPN 已开启后再检测。"
        case .moduleNotIntercepted:
            return "请求没有被第三方模块拦住。请确认模块已启用，并已开启 HTTPS 解密、添加解密域名。"
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
            return "安装代理客户端的 HTTPS 解密证书后，到系统设置 → 通用 → 关于本机 → 证书信任设置，打开完全信任"
        case .proxyNotConnected:
            return "打开代理客户端并开启代理/VPN 连接，确认状态栏出现 VPN 后再检测"
        case .moduleNotIntercepted:
            var suggestion = "确认模块已启用，HTTPS 解密已开，解密域名已添加"
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
            let codes: Set<Int> = [-1200, -1201, -1202, -1203, -1204, -1205, -1206]
            if codes.contains(nsError.code) {
                return true
            }
        }
        let normalized = nsError.localizedDescription.lowercased()
        return normalized.contains("tls")
            || normalized.contains("ssl")
            || normalized.contains("certificate")
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
