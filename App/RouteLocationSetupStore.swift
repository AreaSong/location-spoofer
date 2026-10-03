import Foundation

/// 隧道环境探测和重试节奏。真机用 LocalDevVPN，测试时可整体替换。
struct RouteLocationEnvironment {
    static let maintenanceIntervalNanoseconds: UInt64 = 10_000_000_000

    var isVPNInstalled: @MainActor () -> Bool
    var isTunnelConnected: @MainActor () -> Bool
    var deviceAddress: String
    /// LocalDevVPN 重启后 RSD 要几秒才起来，连不上就按这个间隔再试。
    var tunnelRetryDelaysNanoseconds: [UInt64]
    /// 仅解释观察结果；不能据默认路径阻断本机连接或减少恢复预算。
    var networkObservation: @MainActor () -> DeveloperNetworkObservation
    /// 单调时钟不受系统校时影响；等待可在测试里替换，不依赖真实后台调度。
    var monotonicTime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var waitForMaintenance: @Sendable () async throws -> Void = {
        try await Task.sleep(nanoseconds: maintenanceIntervalNanoseconds)
    }

    static let live = RouteLocationEnvironment(
        isVPNInstalled: { LocalDevVPN.isInstalled },
        isTunnelConnected: { LocalDevVPN.isConnected },
        deviceAddress: LocalDevVPN.defaultAddress,
        tunnelRetryDelaysNanoseconds: [500_000_000, 2_000_000_000, 4_000_000_000],
        networkObservation: { NetworkMonitor.shared.developerObservation }
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

    var simulationStatusText: String {
        if activity.simulationMayStillBeActive { return "可能仍在模拟" }
        return isSimulating ? "已开启" : "已关闭"
    }

    var connectionSummary: String {
        if activity.lastFailure != nil {
            return activity.simulationMayStillBeActive ? "推送或清理失败，旧模拟可能仍生效" : "定位通道未确认可用"
        }
        if isSimulating { return "最近定位推送成功" }
        return readiness == .ready ? "环境可尝试，定位通道待验证" : "隧道环境未就绪"
    }

    private let pairingStore: RoutePairingStore
    private let client: IdeviceLocationPushing
    private let environment: RouteLocationEnvironment
    /// 持有最新提交的任务；取消仅终止未开始部分和重试，不中断同步设备调用。
    private var deviceTask: Task<IdeviceCommandOutcome, Error>?
    private var deviceTaskID: UUID?
    private var writesAllowed = true
    private var monitorTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var maintainedCoordinate: (latitude: Double, longitude: Double)?
    private var lastMaintenanceAttemptAt: TimeInterval?

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

    deinit {
        monitorTask?.cancel()
        maintenanceTask?.cancel()
        deviceTask?.cancel()
    }

    func refresh() {
        // 网卡上下线只更新就绪状态。模拟进行中如果在这里丢掉连接，
        // 隧道一恢复又会新开一条，系统定位就会在两个坐标之间来回跳。
        let connected = environment.isTunnelConnected()
        status = RouteLocationStatus(
            vpnInstalled: environment.isVPNInstalled() || connected,
            tunnelConnected: connected,
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
        stopLocationMaintenance()
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
        guard !isClearing else { return .superseded }
        suspendWrites()
        isClearing = true
        defer { isClearing = false }
        let mutation = client.beginMutation()
        let client = client
        let outcome = await performDevice {
            client.invalidate(mutation: mutation)
        }
        return applyInvalidateResult(outcome, mutation: mutation)
    }

    /// 只有显式开启定点或播放才重新开放；旧生产者不能自行恢复资格。
    @discardableResult
    func resumeWrites() -> Bool {
        guard !isClearing else { return false }
        writesAllowed = true
        return true
    }

    func suspendWrites() {
        guard writesAllowed else { return }
        writesAllowed = false
        stopLocationMaintenance()
        _ = client.beginMutation()
        deviceTask?.cancel()
    }

    func set(latitude: Double, longitude: Double) async -> RouteLocationPushFailure? {
        guard writesAllowed, !isClearing, !Task.isCancelled else { return .superseded }
        // 环境拒绝也是一次新意图，不能让仍在途的旧请求随后覆盖此结果。
        let mutation = client.beginMutation()
        deviceTask?.cancel()
        refresh()
        let current = readiness
        if current != .ready {
            let failure = RouteLocationPushFailure.notReady(current)
            activity.lastFailure = failure
            activity.simulationMayStillBeActive = activity.simulationMayStillBeActive || isSimulating
            isSimulating = false
            return failure
        }
        let path = pairingStore.pairingURL.path
        let address = environment.deviceAddress
        let delays = environment.tunnelRetryDelaysNanoseconds
        let client = client
        // 提交之后即保守记录可能生效；取消不能证明 C 调用没有写入。
        activity.simulationMayStillBeActive = true
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
        let failure = applySetResult(outcome, mutation: mutation)
        if failure == nil {
            maintainedCoordinate = (latitude, longitude)
            lastMaintenanceAttemptAt = environment.monotonicTime()
            startLocationMaintenance()
        }
        return failure
    }

    /// 句柄非空不代表设备端仍在模拟。只重推服务最后成功写入的点，并让正在进行的 set/clear 优先。
    func reassertIfNeeded(force: Bool = true) async -> RouteLocationPushFailure? {
        guard !Task.isCancelled, deviceTask == nil, !isClearing,
              let coordinate = maintainedCoordinate else { return nil }
        let now = environment.monotonicTime()
        let elapsed = now - (lastMaintenanceAttemptAt ?? now)
        let interval = Double(RouteLocationEnvironment.maintenanceIntervalNanoseconds) / 1_000_000_000
        guard force || elapsed >= interval else { return nil }
        lastMaintenanceAttemptAt = now
        let failure = await set(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard failure != .superseded else { return failure }
        let details = ["触发": force ? "前台或隧道恢复" : "定期维持", "距上次写入或尝试秒": String(Int(elapsed))]
        if let failure {
            RuntimeLogger.warning("APP", "隧道", "定位会话补写失败：\(failure.message)", details: details)
        } else {
            RuntimeLogger.info("APP", "隧道", "定位会话已补写", details: details)
        }
        return failure
    }

    private func startLocationMaintenance() {
        guard maintenanceTask == nil else { return }
        let wait = environment.waitForMaintenance
        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await wait() } catch { return }
                guard !Task.isCancelled, let self else { return }
                _ = await self.reassertIfNeeded(force: false)
            }
        }
    }

    private func stopLocationMaintenance() {
        maintainedCoordinate = nil
        lastMaintenanceAttemptAt = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    func clear() async -> RouteLocationPushFailure? {
        // 停止意图立即撤销自动补写；即使 clear 失败，也不能再把定位重新开启。
        guard !isClearing else { return .superseded }
        suspendWrites()
        isClearing = true
        defer { isClearing = false }
        let mutation = client.beginMutation()
        // 快照可能落后于在途 set；是否需要连接必须在设备队列内判断。
        let reconnect = activity.simulationMayStillBeActive || isSimulating
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
        mutation: UInt64
    ) -> RouteLocationPushFailure? {
        guard !Task.isCancelled, client.currentMutation() == mutation else { return .superseded }
        switch outcome {
        case .superseded:
            return .superseded
        case .finished(let failure):
            let observation = environment.networkObservation()
            let reported = Self.explained(failure, observation: observation)
            activity.lastSetAt = Date()
            activity.lastFailure = reported
            guard let reported else {
                isSimulating = true
                activity.simulationMayStillBeActive = false
                return nil
            }
            var details = observation.diagnosticDetails
            details["阶段"] = "set"
            details["失败类别"] = String(describing: failure)
            details["定位意图有效"] = String(writesAllowed)
            RuntimeLogger.warning("APP", "隧道", "定位推送未确认成功", details: details)
            // 失败后立刻丢掉半开隧道，避免占到系统隔夜才回收。
            client.abandonSession()
            if isSimulating {
                activity.simulationMayStillBeActive = true
            }
            isSimulating = false
            // 推送失败先看隧道是不是断了，把具体原因告诉用户。
            refresh()
            if readiness != .ready {
                activity.lastFailure = .notReady(readiness)
                return .notReady(readiness)
            }
            return reported
        }
    }

    private static func explained(
        _ failure: RouteLocationPushFailure?,
        observation: DeveloperNetworkObservation
    ) -> RouteLocationPushFailure? {
        if failure == .tunnel, observation.usesCellular, !observation.usesWiFi {
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
            } else {
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

    /// 取消待执行部分及重试；已进入同步 C 调用的任务仍需等返回，再由后续 clear 收敛。
    private func performDevice(
        _ operation: @escaping @Sendable () async throws -> IdeviceCommandOutcome
    ) async -> IdeviceCommandOutcome {
        deviceTask?.cancel()
        let id = UUID()
        deviceTaskID = id
        let task = Task.detached(operation: operation)
        deviceTask = task
        defer {
            if deviceTaskID == id {
                deviceTask = nil
                deviceTaskID = nil
            }
        }
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
        try Task.checkCancellation()
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
