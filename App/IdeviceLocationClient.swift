import Foundation

#if !targetEnvironment(simulator)
import IdeviceLocation
#endif

/// 一次设备调用的结果。`superseded` 只表示未执行的操作已失效；已开始的同步调用仍可能产生副作用。
enum IdeviceCommandOutcome: Equatable, Sendable {
    case finished(RouteLocationPushFailure?)
    case superseded
}

/// 能把坐标推进系统定位的通道。就绪判断和重试节奏由 RouteLocationSetupStore 负责。
protocol IdeviceLocationPushing: AnyObject, Sendable {
    /// 同步占一个新序号。之后开始的调用会让还没进临界区的旧调用失效。
    func beginMutation() -> UInt64
    func currentMutation() -> UInt64
    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome
    func clear(mutation: UInt64) -> IdeviceCommandOutcome
    /// 本地是否还握着系统定位模拟句柄。没有句柄时，clear 不能当成已经关掉模拟。
    var retainsSimulation: Bool { get }
    /// 尝试 clear，然后丢掉握手。clear 失败时句柄也不再留着，调用方要记「可能仍在生效」。
    func invalidate(mutation: UInt64) -> IdeviceCommandOutcome
    /// 句柄已经丢了，用当前配对文件重新连上再 clear。
    func clearReconnecting(
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome
    /// 丢掉本地句柄，不再向已死套接字发 clear。隧道掉线后下次 set 才能干净重连。
    func abandonSession()
}

/// 通过 idevice 把坐标推进系统定位。模拟器没有这条通道。
/// 每次调用只连一次：连不上直接返回 `.tunnel`，不在串行队列里睡眠等待。
final class IdeviceLocationClient: IdeviceLocationPushing, @unchecked Sendable {
    static let shared = IdeviceLocationClient()
    static let tunnelPort = LocalDevVPN.tunnelPort
    static let hostname = "PaopaoLocation"

    private let queue = DispatchQueue(label: "com.paopaolabs.location-spoofer.idevice")
    // 短锁只保护序号和句柄快照，绝不持锁调用设备或等待 queue。
    private let stateLock = NSLock()
    private var mutation: UInt64 = 0
    private var retainedSnapshot = false

    /// 测试接缝仍在真实串行队列内执行，不替换调度模型。
    struct DeviceOperations: Sendable {
        var set: @Sendable (Double, Double) -> RouteLocationPushFailure?
        var clear: @Sendable () -> RouteLocationPushFailure?
        var abandon: @Sendable () -> Void
        var retainsSimulation: @Sendable () -> Bool
        var clearReconnecting: (@Sendable () -> RouteLocationPushFailure?)? = nil
    }
    private let operations: DeviceOperations?

    init(operations: DeviceOperations? = nil) {
        self.operations = operations
    }

    private func publishHandleSnapshot() {
        let retained: Bool
        if let operations {
            retained = operations.retainsSimulation()
        } else {
            #if targetEnvironment(simulator)
            retained = false
            #else
            retained = simulation != nil
            #endif
        }
        stateLock.lock()
        retainedSnapshot = retained
        stateLock.unlock()
    }
    #if !targetEnvironment(simulator)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var simulation: OpaquePointer?
    #endif

    func beginMutation() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        mutation &+= 1
        return mutation
    }

    func currentMutation() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mutation
    }

    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome {
        queue.sync {
            guard mutation == currentMutation() else { return .superseded }
            defer { publishHandleSnapshot() }
            return .finished(setLocked(
                latitude: latitude,
                longitude: longitude,
                pairingPath: pairingPath,
                deviceAddress: deviceAddress
            ))
        }
    }

    func clear(mutation: UInt64) -> IdeviceCommandOutcome {
        queue.sync {
            guard mutation == currentMutation() else { return .superseded }
            defer { publishHandleSnapshot() }
            return .finished(clearLocked())
        }
    }

    var retainsSimulation: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retainedSnapshot
    }

    func invalidate(mutation: UInt64) -> IdeviceCommandOutcome {
        queue.sync {
            guard mutation == currentMutation() else { return .superseded }
            defer { publishHandleSnapshot() }
            if let operations {
                let failure = operations.clear()
                operations.abandon()
                return .finished(failure)
            }
            #if targetEnvironment(simulator)
            return .finished(nil)
            #else
            let failure = clearLocked()
            releaseSession()
            return .finished(failure)
            #endif
        }
    }

    func clearReconnecting(
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome {
        queue.sync {
            guard mutation == currentMutation() else { return .superseded }
            defer { publishHandleSnapshot() }
            if let operations {
                return .finished((operations.clearReconnecting ?? operations.clear)())
            }
            #if targetEnvironment(simulator)
            _ = pairingPath
            _ = deviceAddress
            return .finished(.tunnel)
            #else
            if simulation == nil {
                if let failure = connectLocked(pairingPath: pairingPath, deviceAddress: deviceAddress) {
                    return .finished(failure)
                }
            }
            return .finished(clearLocked())
            #endif
        }
    }

    func abandonSession() {
        queue.async { [self] in
            defer { publishHandleSnapshot() }
            if let operations {
                operations.abandon()
                return
            }
            #if !targetEnvironment(simulator)
            abandonSessionLocked()
            #endif
        }
    }

    private func setLocked(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String
    ) -> RouteLocationPushFailure? {
        if let operations { return operations.set(latitude, longitude) }
        #if targetEnvironment(simulator)
        _ = latitude
        _ = longitude
        _ = pairingPath
        _ = deviceAddress
        return .rejected
        #else
        if simulation != nil {
            guard let error = location_simulation_set(simulation, latitude, longitude) else { return nil }
            idevice_error_free(error)
            // 旧套接字已死。再 clear 会堵在串行队列上，重启 LocalDevVPN 也解不开。
            abandonSessionLocked()
        }
        return openSession(
            latitude: latitude,
            longitude: longitude,
            pairingPath: pairingPath,
            deviceAddress: deviceAddress
        )
        #endif
    }

    private func clearLocked() -> RouteLocationPushFailure? {
        if let operations { return operations.clear() }
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let simulation else { return nil }
        if let error = location_simulation_clear(simulation) {
            idevice_error_free(error)
            // 句柄留着，调用方才能再清一次；先释放的话下次 clear 会空成功。
            return .clearFailed
        }
        releaseSession()
        return nil
        #endif
    }

    #if !targetEnvironment(simulator)
    private func abandonSessionLocked() {
        releaseSession()
    }

    private func openSession(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String
    ) -> RouteLocationPushFailure? {
        if let failure = connectLocked(pairingPath: pairingPath, deviceAddress: deviceAddress) {
            return failure
        }
        if let setFailed = location_simulation_set(simulation, latitude, longitude) {
            idevice_error_free(setFailed)
            releaseSession()
            return .rejected
        }
        return nil
    }

    private func connectLocked(pairingPath: String, deviceAddress: String) -> RouteLocationPushFailure? {
        abandonSessionLocked()
        var pairing: OpaquePointer?
        let readFailed = pairingPath.withCString { rp_pairing_file_read($0, &pairing) }
        if let readFailed {
            idevice_error_free(readFailed)
            return .pairing
        }
        guard let pairing else { return .pairing }
        defer { rp_pairing_file_free(pairing) }

        let hostnames = hostnameCandidates(pairingPath: pairingPath)
        let endpoints = tunnelEndpointsToTry(preferred: deviceAddress)
        RuntimeLogger.info("APP", "隧道", "开始连接本机隧道", details: [
            "地址": endpoints.joined(separator: ","),
            "主机身份": hostnames.joined(separator: ",")
        ])
        for endpoint in endpoints {
            for hostname in hostnames {
                if let failure = connectOnce(
                    deviceAddress: endpoint,
                    hostname: hostname,
                    pairing: pairing
                ) {
                    if failure != .tunnel {
                        return failure
                    }
                    continue
                }
                RuntimeLogger.info("APP", "隧道", "本机隧道已连接", details: [
                    "地址": endpoint,
                    "主机身份": hostname
                ])
                return nil
            }
        }
        return .tunnel
    }

    private func hostnameCandidates(pairingPath: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            names.append(trimmed)
        }
        add(RoutePairingStore.hostIdentity(at: URL(fileURLWithPath: pairingPath)) ?? "")
        add(Self.hostname)
        return names
    }

    private func tunnelEndpointsToTry(preferred: String) -> [String] {
        let endpoints = LocalDevVPN.liveTunnelEndpoints(preferred: preferred)
        let reachable = endpoints.filter { LocalDevVPN.canOpenTunnel(at: $0) }
        if !reachable.isEmpty { return reachable }
        return endpoints
    }

    private func connectOnce(
        deviceAddress: String,
        hostname: String,
        pairing: OpaquePointer
    ) -> RouteLocationPushFailure? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.tunnelPort.bigEndian
        guard deviceAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return .tunnel
        }

        let tunnelFailed = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                hostname.withCString { host in
                    tunnel_create_rppairing(
                        sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        host,
                        pairing,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }
        if let tunnelFailed {
            idevice_error_free(tunnelFailed)
            releaseSession()
            return .tunnel
        }

        if let serverFailed = remote_server_connect_rsd(adapter, handshake, &server) {
            idevice_error_free(serverFailed)
            releaseSession()
            return .tunnel
        }
        if let simulationFailed = location_simulation_new(server, &simulation) {
            idevice_error_free(simulationFailed)
            releaseSession()
            return .rejected
        }
        return nil
    }

    private func releaseSession() {
        if let simulation {
            location_simulation_free(simulation)
            self.simulation = nil
        }
        // simulation 借用 server，必须先释放 simulation。
        if let server {
            remote_server_free(server)
            self.server = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
    #endif
}
