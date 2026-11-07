import Foundation

struct ThirdPartyCompatibility: Identifiable, Equatable {
    var client: ThirdPartyProxyClient
    var moduleFile: String
    var moduleImport: String
    var scriptStorage: String
    var httpsDecrypt: String
    var wlocRewrite: String
    var deviceStatus: String
    var note: String

    var id: String { client.rawValue }
    var isDeviceVerified: Bool { deviceStatus == Self.verifiedStatus }

    static let quantumultXControlSetup = "Quantumult X：仅导入重写订阅不够。请在主配置 [dns] 添加 address = /location-spoofer.invalid/192.0.2.1；在 [filter_local] 添加 host, location-spoofer.invalid, direct 和 ip-cidr, 127.0.0.0/8, direct。保留原有配置，并启用规则分流。"

    static let verifiedStatus = "已在真机验证"
    static let unverifiedStatus = "尚未真机验证"
    static let ios27MITMNote = "部分设备的 Apple 定位域名存在证书固定校验限制，iOS 26.7.2 已观察到。独立控制接口通过不代表系统定位可改写；实际定位仍需真机验证，受限时可评估开发者隧道模式。"
}

enum ThirdPartyCompatibilityMatrix {
    static let rows: [ThirdPartyCompatibility] = [
        row(.shadowrocket, note: "独立 HTTPS 探测已验证；新版坐标控制与定位效果待验证"),
        row(.surge, note: "配置已提供"),
        row(.quantumultX, note: "配置已提供"),
        row(.loon, note: "配置已提供"),
        row(.stash, note: "配置已提供"),
        row(.egern, note: "使用 Surge 模块，配置已提供")
    ]

    static func row(for client: ThirdPartyProxyClient) -> ThirdPartyCompatibility {
        rows.first { $0.client == client } ?? rows[0]
    }

    private static func row(
        _ client: ThirdPartyProxyClient,
        deviceStatus: String = ThirdPartyCompatibility.unverifiedStatus,
        note: String
    ) -> ThirdPartyCompatibility {
        ThirdPartyCompatibility(
            client: client,
            moduleFile: client.moduleFileName,
            moduleImport: "已提供",
            scriptStorage: "已提供",
            httpsDecrypt: "依赖客户端",
            wlocRewrite: "已提供",
            deviceStatus: deviceStatus,
            note: note
        )
    }
}
