import Foundation
import Darwin

struct CertificateAuthority: Equatable {
    let certPEM: String
    let keyPEM: String
}

enum CoreBridgeError: LocalizedError {
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .generationFailed: return "无法生成本地证书"
        }
    }
}

enum CoreBridge {
    static func isValidCertificateAuthority(_ authority: CertificateAuthority) -> Bool {
        authority.certPEM.withCString { certificate in
            authority.keyPEM.withCString { key in
                wloccore_validateca(UnsafeMutablePointer(mutating: certificate), UnsafeMutablePointer(mutating: key)) != 0
            }
        }
    }

    static func generateCertificateAuthority() throws -> CertificateAuthority {
        RuntimeLogger.info("APP", "Core.CA", "调用 Go Core 生成 CA")
        let result = wloccore_generateca()
        guard let certPointer = result.r0, let keyPointer = result.r1 else {
            flushLogs(category: "CA")
            throw CoreBridgeError.generationFailed
        }
        defer { free(certPointer); free(keyPointer) }
        RuntimeLogger.info("APP", "Core.CA", "Go Core CA 生成成功")
        flushLogs(category: "CA")
        return CertificateAuthority(certPEM: String(cString: certPointer), keyPEM: String(cString: keyPointer))
    }

    /// 调用 Go Core 做一次模拟 wloc 响应改写测试，验证定位数据是否会被改成目标坐标。
    static func testWlocPatch(lat: Double, lon: Double, accuracy: Int) -> String {
        guard let ptr = wloccore_testpatch(CDouble(lat), CDouble(lon), CInt(accuracy)) else {
            return "error: null result"
        }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    static func flushLogs(category: String) {
        guard let pointer = wloccore_drainlogs() else { return }
        defer { free(pointer) }
        String(cString: pointer).split(separator: "\n").forEach {
            RuntimeLogger.info("CORE", category, String($0))
        }
    }

    static func refreshVerifyToken() -> String {
        guard let ptr = wloccore_refreshverifytoken() else { return "" }
        defer { free(ptr) }
        return String(cString: ptr)
    }
}
