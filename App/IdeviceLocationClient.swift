import Foundation

#if !targetEnvironment(simulator)
import IdeviceLocation
#endif

/// 通过 idevice 把坐标推进系统定位。模拟器没有这条通道。
final class IdeviceLocationClient: @unchecked Sendable {
    static let shared = IdeviceLocationClient()
    static let tunnelPort: UInt16 = 49152
    static let hostname = "PaopaoLocation"

    private let queue = DispatchQueue(label: "com.paopaolabs.location-spoofer.idevice")
    #if !targetEnvironment(simulator)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var simulation: OpaquePointer?
    #endif

    func set(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String
    ) -> RouteLocationPushFailure? {
        queue.sync {
            setLocked(
                latitude: latitude,
                longitude: longitude,
                pairingPath: pairingPath,
                deviceAddress: deviceAddress
            )
        }
    }

    func clear() {
        queue.sync { clearLocked() }
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
        if let simulation {
            if location_simulation_set(simulation, latitude, longitude) == nil {
                return nil
            }
            releaseSession()
        }
        return openSession(
            latitude: latitude,
            longitude: longitude,
            pairingPath: pairingPath,
            deviceAddress: deviceAddress
        )
        #endif
    }

    private func clearLocked() {
        #if !targetEnvironment(simulator)
        guard let simulation else { return }
        if let error = location_simulation_clear(simulation) {
            idevice_error_free(error)
        }
        releaseSession()
        #endif
    }

    #if !targetEnvironment(simulator)
    private func openSession(
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceAddress: String
    ) -> RouteLocationPushFailure? {
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

        var server: OpaquePointer?
        if let serverFailed = remote_server_connect_rsd(adapter, handshake, &server) {
            idevice_error_free(serverFailed)
            releaseSession()
            return .tunnel
        }
        if let simulationFailed = location_simulation_new(server, &simulation) {
            idevice_error_free(simulationFailed)
            remote_server_free(server)
            releaseSession()
            return .rejected
        }
        if let setFailed = location_simulation_set(simulation, latitude, longitude) {
            idevice_error_free(setFailed)
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
