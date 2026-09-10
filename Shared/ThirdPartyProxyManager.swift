import Foundation

struct ThirdPartyProxySettingsResponse: Decodable, Equatable {
    let success: Bool
    let longitude: Double?
    let latitude: Double?
    let accuracy: Int?
    let error: String?
    let motionSimulationEnabled: Bool?
}

enum ThirdPartyProxyConnectionState: Equatable {
    case unknown
    case connected(active: Bool)
    case failed(String)
}

enum ThirdPartyProxyError: LocalizedError, Equatable {
    case invalidResponse
    case moduleNotIntercepted
    case rejected(String)
    case coordinateMismatch
    case network(String)
    case certificateUntrusted
    case proxyNotConnected

    var diagnosis: ThirdPartyProxyDiagnosis {
        switch self {
        case .invalidResponse:
            return .invalidResponse
        case .moduleNotIntercepted:
            return .moduleNotIntercepted
        case .rejected(let message):
            return .rejected(message)
        case .coordinateMismatch:
            return .coordinateMismatch
        case .network(let message):
            return .network(message)
        case .certificateUntrusted:
            return .certificateUntrusted
        case .proxyNotConnected:
            return .proxyNotConnected
        }
    }

    var errorDescription: String? {
        diagnosis.summary
    }

    var recoverySuggestion: String {
        diagnosis.recoverySuggestion(usingOnDeviceModule: false, localServerRunning: true)
    }

    static func fromTransport(_ error: Error) -> ThirdPartyProxyError {
        switch ThirdPartyProxyDiagnosis.fromTransport(error) {
        case .certificateUntrusted:
            return .certificateUntrusted
        case .proxyNotConnected:
            return .proxyNotConnected
        case .network(let message):
            return .network(message)
        case .invalidResponse:
            return .invalidResponse
        case .moduleNotIntercepted:
            return .moduleNotIntercepted
        case .rejected(let message):
            return .rejected(message)
        case .coordinateMismatch:
            return .coordinateMismatch
        }
    }

    static func diagnosis(for error: Error) -> ThirdPartyProxyDiagnosis {
        (error as? Self)?.diagnosis ?? .fromTransport(error)
    }

    @MainActor
    static func recoverySuggestion(for error: Error) -> String {
        recoverySuggestion(
            for: error,
            usingOnDeviceModule: ThirdPartyModuleSourceStore.shared.distribution == .onDevice,
            localServerRunning: ThirdPartyModuleServer.shared.isRunning
        )
    }

    static func recoverySuggestion(
        for error: Error,
        usingOnDeviceModule: Bool,
        localServerRunning: Bool
    ) -> String {
        diagnosis(for: error).recoverySuggestion(
            usingOnDeviceModule: usingOnDeviceModule,
            localServerRunning: localServerRunning
        )
    }
}

protocol ThirdPartyProxyRequesting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ThirdPartyProxyRequesting {}

@MainActor
final class ThirdPartyProxyManager: ObservableObject {
    static let shared = ThirdPartyProxyManager()
    static let interceptionHostnames = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com"
    ]
    static let interceptionHostnamesText = interceptionHostnames.joined(separator: ", ")
    static let configurationEndpoint = URL(string: "https://gs-loc.apple.com/wloc-settings/save")!

    @Published private(set) var connectionState: ThirdPartyProxyConnectionState = .unknown
    @Published private(set) var activeSettings: ThirdPartyProxySettingsResponse?
    @Published private(set) var isRequesting = false
    private let requester: any ThirdPartyProxyRequesting
    private let randomRadiusMeters: () -> Double

    init(
        requester: (any ThirdPartyProxyRequesting)? = nil,
        randomRadiusMeters: (() -> Double)? = nil
    ) {
        self.randomRadiusMeters = randomRadiusMeters ?? {
            RandomRadiusStore.shared.effectiveRadiusMeters
        }
        if let requester {
            self.requester = requester
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            self.requester = URLSession(configuration: configuration)
        }
    }

    func query() async throws -> ThirdPartyProxySettingsResponse {
        let response = try await perform(action: .query)
        let active = try validatedQueryState(response)
        if active {
            activeSettings = response
            connectionState = .connected(active: true)
        } else {
            activeSettings = nil
            connectionState = .connected(active: false)
        }
        return response
    }

    func save(_ favorite: FavoriteLocation) async throws -> ThirdPartyProxySettingsResponse {
        let wgs84 = favorite.coordinatePair.wgs84
        let radius = randomRadiusMeters()
        let response = try await perform(action: .save(
            latitude: wgs84.latitude,
            longitude: wgs84.longitude,
            accuracy: favorite.accuracy,
            randomRadius: radius
        ))
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? "第三方代理拒绝保存坐标")
        }
        guard let latitude = response.latitude,
              let longitude = response.longitude,
              abs(latitude - wgs84.latitude) <= 0.000_001,
              abs(longitude - wgs84.longitude) <= 0.000_001 else {
            throw ThirdPartyProxyError.coordinateMismatch
        }
        activeSettings = response
        connectionState = .connected(active: true)
        RuntimeLogger.info("APP", "ThirdPartyProxy", "第三方代理已保存 WGS-84 坐标", details: [
            "坐标标准": "WGS-84",
            "取值字段": "coordinatePair.wgs84",
            "accuracy": String(favorite.accuracy),
            "randomRadius": String(radius)
        ])
        return response
    }

    func clear() async throws {
        let response = try await perform(action: .clear)
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? "第三方代理清除坐标失败")
        }
        activeSettings = nil
        connectionState = .connected(active: false)
        RuntimeLogger.info("APP", "ThirdPartyProxy", "第三方代理坐标已清除")
    }

    private func validatedQueryState(_ response: ThirdPartyProxySettingsResponse) throws -> Bool {
        if response.success,
           response.latitude != nil,
           response.longitude != nil {
            return true
        }
        if response.error?.contains("无已保存") == true {
            return false
        }
        throw ThirdPartyProxyError.rejected(response.error ?? "第三方代理查询失败")
    }

    private enum Action {
        case query
        case save(latitude: Double, longitude: Double, accuracy: Int, randomRadius: Double)
        case clear
    }

    private func perform(action: Action) async throws -> ThirdPartyProxySettingsResponse {
        guard !isRequesting else {
            throw ThirdPartyProxyError.rejected("已有第三方代理请求正在执行")
        }
        isRequesting = true
        defer { isRequesting = false }

        var components = URLComponents(url: Self.configurationEndpoint, resolvingAgainstBaseURL: false)!
        switch action {
        case .query:
            components.queryItems = [URLQueryItem(name: "action", value: "query")]
        case .clear:
            components.queryItems = [URLQueryItem(name: "action", value: "clear")]
        case .save(let latitude, let longitude, let accuracy, let randomRadius):
            components.queryItems = [
                URLQueryItem(name: "lon", value: String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), longitude)),
                URLQueryItem(name: "lat", value: String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), latitude)),
                URLQueryItem(name: "acc", value: String(accuracy)),
                URLQueryItem(name: "randomRadius", value: String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), randomRadius))
            ]
        }
        guard let url = components.url else { throw ThirdPartyProxyError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, urlResponse) = try await requester.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse, http.statusCode == 200 else {
                throw ThirdPartyProxyError.moduleNotIntercepted
            }
            guard let response = try? JSONDecoder().decode(ThirdPartyProxySettingsResponse.self, from: data) else {
                throw ThirdPartyProxyError.moduleNotIntercepted
            }

            return response
        } catch let error as ThirdPartyProxyError {
            connectionState = .failed(error.diagnosis.title)
            RuntimeLogger.error("APP", "ThirdPartyProxy", "第三方代理请求失败", error: error, details: [
                "原因": error.diagnosis.title
            ])
            throw error
        } catch {
            let mapped = ThirdPartyProxyError.fromTransport(error)
            connectionState = .failed(mapped.diagnosis.title)
            RuntimeLogger.error("APP", "ThirdPartyProxy", "第三方代理请求失败", error: error, details: [
                "原因": mapped.diagnosis.title
            ])
            throw mapped
        }
    }
}

enum ThirdPartyProxyClient: String, CaseIterable, Identifiable {
    case shadowrocket
    case surge
    case quantumultX
    case loon
    case stash
    case egern

    var id: String { rawValue }

    var name: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .surge: return "Surge"
        case .quantumultX: return "Quantumult X"
        case .loon: return "Loon"
        case .stash: return "Stash"
        case .egern: return "Egern"
        }
    }

    var verificationText: String? {
        self == .shadowrocket ? nil : "配置已提供，尚未验证"
    }

    var moduleFileName: String {
        switch self {
        case .shadowrocket: return "wloc.module"
        case .surge, .egern: return "wloc.sgmodule"
        case .quantumultX: return "wloc.conf"
        case .loon: return "wloc.lpx"
        case .stash: return "wloc.stoverride"
        }
    }

    func subscriptionURL(for distribution: ThirdPartyModuleDistribution) -> URL {
        ThirdPartyModuleCatalog.subscriptionURL(
            moduleFileName: moduleFileName,
            distribution: distribution
        )
    }

    @MainActor
    var subscriptionURL: URL {
        subscriptionURL(for: ThirdPartyModuleSourceStore.shared.distribution)
    }

    var launchURL: URL? {
        switch self {
        case .shadowrocket: return URL(string: "shadowrocket://")
        case .surge: return URL(string: "surge://")
        case .quantumultX: return URL(string: "quantumult-x://")
        case .loon: return URL(string: "loon://")
        case .stash: return URL(string: "stash://")
        case .egern: return URL(string: "egern://")
        }
    }
}

@MainActor
final class ThirdPartyProxyClientStore: ObservableObject {
    static let shared = ThirdPartyProxyClientStore()

    private enum Key {
        static let selectedClient = "selectedThirdPartyProxyClient"
    }

    @Published private(set) var selectedClient: ThirdPartyProxyClient
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        selectedClient = defaults.string(forKey: Key.selectedClient)
            .flatMap(ThirdPartyProxyClient.init(rawValue:)) ?? .shadowrocket
    }

    func select(_ client: ThirdPartyProxyClient) {
        selectedClient = client
        defaults.set(client.rawValue, forKey: Key.selectedClient)
    }
}
