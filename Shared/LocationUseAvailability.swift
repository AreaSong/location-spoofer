import Foundation

enum LocationUseBlock: Equatable {
    case signingExpired(String)
    case appModeNeedsWiFi(String)
    case appModeEnvironment(String)
    case thirdParty(String)

    static let title = "当前不能使用定位修改"
    static let openSettingsTitle = "打开设置"

    var message: String {
        switch self {
        case .signingExpired(let message),
             .appModeNeedsWiFi(let message),
             .appModeEnvironment(let message),
             .thirdParty(let message):
            return message
        }
    }
}

enum LocationRuntimeFailure: Equatable {
    case thirdParty(String)
    case appModeEnvironment(String)
}

enum LocationUseAvailability {
    static func current(
        mode: ProxyRuntimeMode,
        wifiEnabled: Bool,
        cellularEnabled: Bool,
        runtimeFailure: LocationRuntimeFailure?,
        signing: SigningExpiryStatus
    ) -> LocationUseBlock? {
        if signing.isExpired {
            return .signingExpired(signing.settingsMessage ?? "免费签名已过期，请用电脑重新签名并安装。")
        }
        if mode == .localWiFi,
           let wifiMessage = AppModeNetworkRequirement.blockedMessage(
            wifiEnabled: wifiEnabled,
            cellularEnabled: cellularEnabled
           ) {
            return .appModeNeedsWiFi(wifiMessage)
        }
        switch (mode, runtimeFailure) {
        case (.thirdParty, .thirdParty(let message)):
            return .thirdParty(message)
        case (.localWiFi, .appModeEnvironment(let message)):
            return .appModeEnvironment(message)
        default:
            return nil
        }
    }
}

@MainActor
final class LocationRuntimeFailureStore: ObservableObject {
    static let shared = LocationRuntimeFailureStore()

    @Published private(set) var failure: LocationRuntimeFailure?

    func record(_ failure: LocationRuntimeFailure) {
        self.failure = failure
    }

    func recordThirdParty(error: Error) {
        record(.thirdParty(ThirdPartyProxyError.diagnosis(for: error).summary))
    }

    func recordThirdParty(message: String) {
        record(.thirdParty(message))
    }

    func recordAppModeEnvironment(_ message: String) {
        record(.appModeEnvironment(message))
    }

    func clearThirdParty() {
        if case .thirdParty = failure {
            failure = nil
        }
    }

    func clearAppMode() {
        if case .appModeEnvironment = failure {
            failure = nil
        }
    }

    func clear() {
        failure = nil
    }
}
