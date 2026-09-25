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
    /// 持有正在进行的设备调用，clear 或新的 set 可以取消它，避免脱离任务树的旧写入。
    private var deviceTask: Task<IdeviceCommandOutcome, Error>?

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
        let mutation = client.beginMutation()
        let path = pairingStore.pairingURL.path
        let address = environment.deviceAddress
        let delay = environment.tunnelRetryDelayNanoseconds
        let client = client
        let outcome = await performDevice {
            try await Self.push(
                client: client,
                latitude: latitude,
                longitude: longitude,
                pairingPath: path,
                deviceAddress: address,
                mutation: mutation,
                retryDelayNanoseconds: delay
            )
        }
        return applySetResult(outcome, mutation: mutation)
    }

    func clear() async -> RouteLocationPushFailure? {
        let mutation = client.beginMutation()
        let client = client
        let outcome = await performDevice {
            client.clear(mutation: mutation)
        }
        return applyClearResult(outcome, mutation: mutation)
    }

    private func applySetResult(
        _ outcome: IdeviceCommandOutcome,
        mutation: UInt64
    ) -> RouteLocationPushFailure? {
        guard client.currentMutation() == mutation else { return .superseded }
        switch outcome {
        case .superseded:
            return .superseded
        case .finished(let failure):
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
    }

    private func applyClearResult(
        _ outcome: IdeviceCommandOutcome,
        mutation: UInt64
    ) -> RouteLocationPushFailure? {
        guard client.currentMutation() == mutation else { return .superseded }
        switch outcome {
        case .superseded:
            return .superseded
        case .finished(let failure):
            if failure == nil {
                isSimulating = false
            }
            return failure
        }
    }

    /// 取消上一次设备调用并持有新任务。父任务取消时，脱离继承链的 detached 任务也会停。
    private func performDevice(
        _ operation: @escaping @Sendable () async throws -> IdeviceCommandOutcome
    ) async -> IdeviceCommandOutcome {
        deviceTask?.cancel()
        let task = Task.detached(operation: operation)
        deviceTask = task
        return await withTaskCancellationHandler {
            do {
                return try await task.value
            } catch is CancellationError {
                return .superseded
            } catch {
                return .finished(.rejected)
            }
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func push(
        client: IdeviceLocationPushing,
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64,
        retryDelayNanoseconds: UInt64
    ) async throws -> IdeviceCommandOutcome {
        var outcome = client.set(
            latitude: latitude,
            longitude: longitude,
            pairingPath: pairingPath,
            deviceAddress: deviceAddress,
            mutation: mutation
        )
        if case .finished(.tunnel) = outcome {
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            try Task.checkCancellation()
            outcome = client.set(
                latitude: latitude,
                longitude: longitude,
                pairingPath: pairingPath,
                deviceAddress: deviceAddress,
                mutation: mutation
            )
        }
        return outcome
    }
}
