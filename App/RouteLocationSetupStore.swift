import Foundation

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
    private let client: IdeviceLocationClient

    init(
        pairingStore: RoutePairingStore = RoutePairingStore(),
        client: IdeviceLocationClient = .shared
    ) {
        self.pairingStore = pairingStore
        self.client = client
        refresh()
    }

    func refresh() {
        status = RouteLocationStatus(
            vpnInstalled: LocalDevVPN.isInstalled,
            tunnelConnected: LocalDevVPN.isConnected,
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
        let client = client
        let path = pairingStore.pairingURL.path
        let address = LocalDevVPN.defaultAddress
        let failure = await Task.detached {
            client.set(
                latitude: latitude,
                longitude: longitude,
                pairingPath: path,
                deviceAddress: address
            )
        }.value
        if failure == nil {
            isSimulating = true
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
}
