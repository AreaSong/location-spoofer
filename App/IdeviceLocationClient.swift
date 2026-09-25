import Foundation

#if !targetEnvironment(simulator)
import IdeviceLocation
#endif

/// 一次设备调用的结果。`superseded` 表示更新的 set/clear 已经占住通道，这次不能改设备状态。
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
}

/// 通过 idevice 把坐标推进系统定位。模拟器没有这条通道。
/// 每次调用只连一次：连不上直接返回 `.tunnel`，不在串行队列里睡眠等待。
final class IdeviceLocationClient: IdeviceLocationPushing, @unchecked Sendable {
    static let shared = IdeviceLocationClient()
    static let tunnelPort: UInt16 = 49152
    static let hostname = "PaopaoLocation"

    private let queue = DispatchQueue(label: "com.paopaolabs.location-spoofer.idevice")
    private var mutation: UInt64 = 0
    #if !targetEnvironment(simulator)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var simulation: OpaquePointer?
    #endif

    func beginMutation() -> UInt64 {
        queue.sync {
            mutation &+= 1
            return mutation
        }
    }

    func currentMutation() -> UInt64 {
        queue.sync { mutation }
    }

    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String,
        mutation: UInt64
    ) -> IdeviceCommandOutcome {
        queue.sync {
            guard mutation == self.mutation else { return .superseded }
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
            guard mutation == self.mutation else { return .superseded }
            return .finished(clearLocked())
        }
    }

    var retainsSimulation: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        queue.sync { simulation != nil }
        #endif
    }

    func invalidate(mutation: UInt64) -> IdeviceCommandOutcome {
        queue.sync {
            guard mutation == self.mutation else { return .superseded }
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
            guard mutation == self.mutation else { return .superseded }
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

    private func setLocked(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String
    ) -> RouteLocationPushFailure? {
        #if targetEnvironment(simulator)
        _ = latitude
        _ = longitude
        _ = pairingPath
        _ = deviceAddress
        return .rejected
        #else
        if simulation != nil {
            if location_simulation_set(simulation, latitude, longitude) == nil {
                return nil
            }
            // 旧套接字已死，丢掉本地句柄后重新连接。
            discardSession()
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
    private func discardSession() {
        if let simulation {
            if let error = location_simulation_clear(simulation) {
                idevice_error_free(error)
            }
        }
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
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.tunnelPort.bigEndian
        guard deviceAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return .tunnel
        }

        var pairing: OpaquePointer?
        let readFailed = pairingPath.withCString { rp_pairing_file_read($0, &pairing) }
        if let readFailed {
            idevice_error_free(readFailed)
            return .pairing
        }
        guard let pairing else { return .pairing }
        defer { rp_pairing_file_free(pairing) }

        let tunnelFailed = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    Self.hostname,
                    pairing,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
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
