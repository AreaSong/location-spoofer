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

    static let verifiedStatus = "已在真机验证"
    static let unverifiedStatus = "尚未真机验证"
    static let ios27MITMNote = "iOS 27 beta 6 起，系统禁止对 gs-loc.apple.com 做 MITM，以上客户端都暂时不可用。"
}

enum ThirdPartyCompatibilityMatrix {
    static let rows: [ThirdPartyCompatibility] = [
        row(.shadowrocket, deviceStatus: ThirdPartyCompatibility.verifiedStatus, note: "当前用于真机测试"),
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
