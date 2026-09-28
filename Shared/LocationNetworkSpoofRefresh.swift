import Foundation

/// 第三方 / APP 模式改的是网络定位响应。iOS 26 起 locationd 缓存更黏，开关定位通常够用，还不跳点再重启手机。
enum LocationNetworkSpoofRefresh {
    static let memoryCacheMajorVersion = 26
    static let mitmBlockedMajorVersion = RuntimeModeAvailability.mitmBlockedMajorVersion

    static let cacheRefreshMessage =
        "iOS 26 起系统定位缓存更黏。第三方代理里保存成功后，先开关一次系统定位服务；还不跳点，再重启手机。"

    static func hasStrongerLocationCache(
        iOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        iOSMajor >= memoryCacheMajorVersion
    }

    static func setupWarning(
        iOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String? {
        if iOSMajor >= mitmBlockedMajorVersion {
            return "iOS 27 beta 6 起，系统已禁止对 gs-loc.apple.com 进行 MITM 拦截。APP 模式和第三方代理模式在该版本及之后不可用。请改用开发者隧道模式。"
        }
        if iOSMajor >= memoryCacheMajorVersion {
            return cacheRefreshMessage
        }
        return nil
    }
}
