import Foundation

/// 第三方 / APP 模式改的是网络定位响应。iOS 26 起 locationd 会长时间复用内存里的真实坐标。
enum LocationNetworkSpoofRefresh {
    static let memoryCacheMajorVersion = 26
    static let mitmBlockedMajorVersion = RuntimeModeAvailability.mitmBlockedMajorVersion

    static let cacheRestartMessage =
        "iOS 26 起系统会把真实定位缓存在内存里。第三方代理里保存成功后，必须重启手机，真实位置才会跳过去。开关飞行模式无效。"

    static func requiresDeviceRestart(
        iOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        iOSMajor >= memoryCacheMajorVersion
    }

    static func setupWarning(
        iOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String? {
        if iOSMajor >= mitmBlockedMajorVersion {
            return "iOS 27 beta 6 起，系统已禁止对 gs-loc.apple.com 进行 MITM 拦截。该版本及之后的 beta 版本暂时无法使用本项目，等待后续适配方案。"
        }
        if iOSMajor >= memoryCacheMajorVersion {
            return cacheRestartMessage
        }
        return nil
    }
}

