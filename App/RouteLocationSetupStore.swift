import Foundation

/// 隧道环境探测和重试节奏。真机用 LocalDevVPN，测试时可整体替换。
struct RouteLocationEnvironment {
    var isVPNInstalled: @MainActor () -> Bool
    var isTunnelConnected: @MainActor () -> Bool
    var deviceAddress: String
    /// LocalDevVPN 重启后 RSD 要几秒才起来，连不上就按这个间隔再试。
    var tunnelRetryDelaysNanoseconds: [UInt64]
    /// 只有蜂窝、没有 Wi-Fi 时，系统通常拒绝开发者隧道握手。
    var isCellularWithoutWiFi: @MainActor () -> Bool

    static let live = RouteLocationEnvironment(
        isVPNInstalled: { LocalDevVPN.isInstalled },
        isTunnelConnected: { LocalDevVPN.isConnected },
        deviceAddress: LocalDevVPN.defaultAddress,
        tunnelRetryDelaysNanoseconds: [500_000_000, 2_000_000_000, 4_000_000_000],
        isCellularWithoutWiFi: {
            NetworkMonitor.shared.usesCellular && !NetworkMonitor.shared.isWiFiEnabled
        }
    )
}

@MainActor
final class RouteLocationSetupStore: ObservableObject, DeveloperLocationPushing {
    static let shared = RouteLocationSetupStore()
    static let tunnelMonitorIntervalNanoseconds: UInt64 = 2_000_000_000

    @Published private(set) var isSimulating = false
    @Published private(set) var isClearing = false
    @Published private(set) var activity = DeveloperTunnelActivity()
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
    private var monitorTask: Task<Void, Never>?

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
        // 网卡上下线只更新就绪状态。模拟进行中如果在这里丢掉连接，
        // 隧道一恢复又会新开一条，系统定位就会在两个坐标之间来回跳。
        status = RouteLocationStatus(
            vpnInstalled: environment.isVPNInstalled(),
            tunnelConnected: environment.isTunnelConnected(),
            hasPairing: pairingStore.hasPairingFile
        )
    }

    func startTunnelMonitor() {
        guard monitorTask == nil else { return }
        refresh()
        monitorTask = Task { @MainActor [weak self] in
            while let store = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tunnelMonitorIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                store.refresh()
            }
        }
    }

    func stopTunnelMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// 丢掉卡住的隧道句柄。隧道仍可用时会先尝试恢复真实定位。不删除配对文件。
    func resetTunnelCache() async -> String {
        refresh()
        var warning: String?
        if isSimulating || activity.simulationMayStillBeActive || client.retainsSimulation {
            if let failure = await clear() {
                warning = failure.message
            }
        }
        dropLocalSession(reason: "cache reset")
        if let warning {
            isSimulating = false
            activity.simulationMayStillBeActive = true
            return "隧道会话已丢掉，但系统定位可能还停在虚拟点。\(warning)"
        }
        isSimulating = false
        activity.simulationMayStillBeActive = false
        return "隧道会话已清理。配对文件还在。"
    }

    func importPairing(_ data: Data) async throws {
        try pairingStore.install(data)
        refresh()
        _ = await invalidateActiveSession()
    }

    /// 先清模拟定位。清不掉就保留文件，避免下次重试没有配对可用。
    func deletePairing() async -> String? {
        if isSimulating || activity.simulationMayStillBeActive || client.retainsSimulation {
            if let failure = await clear() {
                return failure.message
            }
        }
        do {
            try pairingStore.remove()
            refresh()
            return nil
        } catch {
            return "配对文件没有删除。"
        }
    }

    func invalidateActiveSession() async -> RouteLocationPushFailure? {
        let mutation = client.beginMutation()
        let client = client
        let outcome = await performDevice {
            client.invalidate(mutation: mutation)
        }
        return applyInvalidateResult(outcome, mutation: mutation)
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
        let cellularWithoutWiFi = environment.isCellularWithoutWiFi()
        let delays = cellularWithoutWiFi ? [] : environment.tunnelRetryDelaysNanoseconds
        let client = client
        let outcome = await performDevice {
            try await Self.retryingTunnel(delays: delays) {
                client.set(
                    latitude: latitude,
                    longitude: longitude,
                    pairingPath: path,
                    deviceAddress: address,
                    mutation: mutation
                )
            }
        }
        return applySetResult(outcome, mutation: mutation, cellularWithoutWiFi: cellularWithoutWiFi)
    }

    /// 连接还在时不要再推。恢复拿到的是上次坐标，和正在写入的点叠在一起就会来回跳。
    func reassertIfNeeded(latitude: Double, longitude: Double) async -> RouteLocationPushFailure? {
        guard !client.retainsSimulation else { return nil }
        return await set(latitude: latitude, longitude: longitude)
    }

    func clear() async -> RouteLocationPushFailure? {
        isClearing = true
        defer { isClearing = false }
        let mutation = client.beginMutation()
        let reconnect = activity.simulationMayStillBeActive && !client.retainsSimulation
        let path = pairingStore.pairingURL.path
        let address = environment.deviceAddress
        let delays = environment.tunnelRetryDelaysNanoseconds
        let client = client
        let outcome = await performDevice {
            if reconnect {
                return try await Self.retryingTunnel(delays: delays) {
                    client.clearReconnecting(
                        pairingPath: path,
                        deviceAddress: address,
                        mutation: mutation
                    )
                }
            }
            return client.clear(mutation: mutation)
        }
        return applyClearResult(outcome, mutation: mutation)
    }

    private func dropLocalSession(reason: String) {
        let hasSession = isSimulating || activity.simulationMayStillBeActive || client.retainsSimulation
        guard hasSession else { return }
        client.abandonSession()
        if isSimulating {
            activity.simulationMayStillBeActive = true
        }
        RuntimeLogger.warning("APP", "隧道", "已丢掉旧会话，等待设备侧回收隧道", details: [
            "原因": reason,
            "模拟可能仍在生效": String(activity.simulationMayStillBeActive)
        ])
    }

    private func applySetResult(
        _ outcome: IdeviceCommandOutcome,
        mutation: UInt64,
        cellularWithoutWiFi: Bool = false
    ) -> RouteLocationPushFailure? {
        guard client.currentMutation() == mutation else { return .superseded }
        switch outcome {
        case .superseded:
            return .superseded
        case .finished(let failure):
            let reported = Self.explained(failure, cellularWithoutWiFi: cellularWithoutWiFi)
            activity.lastSetAt = Date()
            activity.lastFailure = reported
            guard let reported else {
                isSimulating = true
                activity.simulationMayStillBeActive = false
                return nil
            }
            // 失败后立刻丢掉半开隧道，避免占到系统隔夜才回收。
            client.abandonSession()
            if isSimulating {
                activity.simulationMayStillBeActive = true
            }
            // 推送失败先看隧道是不是断了，把具体原因告诉用户。
            refresh()
            if readiness != .ready {
                isSimulating = false
                return .notReady(readiness)
            }
            return reported
        }
    }

    private static func explained(
        _ failure: RouteLocationPushFailure?,
        cellularWithoutWiFi: Bool
    ) -> RouteLocationPushFailure? {
        if failure == .tunnel, cellularWithoutWiFi {
            return .tunnelOnCellular
        }
        return failure
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
            activity.lastClearAt = Date()
            activity.lastFailure = failure
            if failure == nil {
                isSimulating = false
                activity.simulationMayStillBeActive = false
            } else if failure == .clearFailed {
                activity.simulationMayStillBeActive = true
            }
            return failure
        }
    }

    private func applyInvalidateResult(
        _ outcome: IdeviceCommandOutcome,
        mutation: UInt64
    ) -> RouteLocationPushFailure? {
        guard client.currentMutation() == mutation else { return .superseded }
        switch outcome {
        case .superseded:
            return .superseded
        case .finished(let failure):
            activity.lastClearAt = Date()
            activity.lastFailure = failure
            if failure == nil {
                isSimulating = false
                activity.simulationMayStillBeActive = false
            } else {
                activity.simulationMayStillBeActive = true
                isSimulating = true
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

    nonisolated private static func retryingTunnel(
        delays: [UInt64],
        operation: () -> IdeviceCommandOutcome
    ) async throws -> IdeviceCommandOutcome {
        var remaining = delays
        var outcome = operation()
        while case .finished(.tunnel) = outcome, let delay = remaining.first {
            remaining.removeFirst()
            RuntimeLogger.warning("APP", "隧道", "本机隧道连不上，准备重试", details: [
                "等待毫秒": String(delay / 1_000_000),
                "剩余次数": String(remaining.count + 1)
            ])
            try await Task.sleep(nanoseconds: delay)
            try Task.checkCancellation()
            outcome = operation()
        }
        return outcome
    }
}
