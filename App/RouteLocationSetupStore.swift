import Foundation

/// 隧道环境探测和重试节奏。真机用 LocalDevVPN，测试时可整体替换。
struct RouteLocationEnvironment {
    var isVPNInstalled: @MainActor () -> Bool
    var isTunnelConnected: @MainActor () -> Bool
    var deviceAddress: String
    /// 手机放开上一条隧道需要一点时间，连不上时等这么久再试一次。
    var tunnelRetryDelayNanoseconds: UInt64

    static let live = RouteLocationEnvironment(
        isVPNInstalled: { LocalDevVPN.isInstalled },
        isTunnelConnected: { LocalDevVPN.isConnected },
        deviceAddress: LocalDevVPN.defaultAddress,
        tunnelRetryDelayNanoseconds: 500_000_000
    )
}

@MainActor
final class RouteLocationSetupStore: ObservableObject, DeveloperLocationPushing {
    static let shared = RouteLocationSetupStore()

    @Published private(set) var isSimulating = false
    @Published private(set) var status = RouteLocationStatus(
        vpnInstalled: false,
        tunnelConnected: false,
        hasPairing: false
    )

    var readiness: RouteLocationReadiness { status.readiness }

    private let pairingStore: RoutePairingStore
    private let client: IdeviceLocationPushing
    private let environment: RouteLocationEnvironment

    init(
        pairingStore: RoutePairingStore = RoutePairingStore(),
        client: IdeviceLocationPushing = IdeviceLocationClient.shared,
        environment: RouteLocationEnvironment = .live
    ) {
        self.pairingStore = pairingStore
        self.client = client
        self.environment = environment
        refresh()
    }

    func refresh() {
        status = RouteLocationStatus(
            vpnInstalled: environment.isVPNInstalled(),
            tunnelConnected: environment.isTunnelConnected(),
            hasPairing: pairingStore.hasPairingFile
        )
    }

    func importPairing(_ data: Data) throws {
        try pairingStore.install(data)
        refresh()
    }

    func set(latitude: Double, longitude: Double) async -> RouteLocationPushFailure? {
        refresh()
        let current = readiness
        if current != .ready {
            return .notReady(current)
        }
        var failure = await push(latitude: latitude, longitude: longitude)
        if failure == .tunnel {
            try? await Task.sleep(nanoseconds: environment.tunnelRetryDelayNanoseconds)
            failure = await push(latitude: latitude, longitude: longitude)
        }
        guard let failure else {
            isSimulating = true
            return nil
        }
        // 推送失败先看隧道是不是断了，把具体原因告诉用户。
        refresh()
        if readiness != .ready {
            isSimulating = false
            return .notReady(readiness)
        }
        return failure
    }

    func clear() async {
        let client = client
        await Task.detached {
            client.clear()
        }.value
        isSimulating = false
    }

    private func push(latitude: Double, longitude: Double) async -> RouteLocationPushFailure? {
        let client = client
        let path = pairingStore.pairingURL.path
        let address = environment.deviceAddress
        return await Task.detached {
            client.set(
                latitude: latitude,
                longitude: longitude,
                pairingPath: path,
                deviceAddress: address
            )
        }.value
    }
}
