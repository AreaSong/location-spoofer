import Foundation

enum Socks5Protocol {
    static let version: UInt8 = 0x05
    static let noAuth: UInt8 = 0x00
    static let connectCommand: UInt8 = 0x01
    static let atypIPv4: UInt8 = 0x01
    static let atypDomain: UInt8 = 0x03
    static let atypIPv6: UInt8 = 0x04

    struct Target: Equatable {
        var host: String
        var port: UInt16
    }

    enum ParseError: Error, Equatable {
        case incomplete
        case invalid
        case unsupported
    }

    static let methodReply = Data([version, noAuth])
    static let succeededReply = Data([version, 0x00, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0])
    static let failedReply = Data([version, 0x01, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0])
    static let unsupportedReply = Data([version, 0x07, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0])

    static func greetingConsumption(in data: Data) -> Result<Int, ParseError> {
        guard data.count >= 2 else { return .failure(.incomplete) }
        guard data[0] == version else { return .failure(.invalid) }
        let total = 2 + Int(data[1])
        guard data.count >= total else { return .failure(.incomplete) }
        return .success(total)
    }

    static func request(from data: Data) -> Result<(Target, Int), ParseError> {
        guard data.count >= 5 else { return .failure(.incomplete) }
        guard data[0] == version, data[2] == 0x00 else { return .failure(.invalid) }
        guard data[1] == connectCommand else { return .failure(.unsupported) }
        switch data[3] {
        case atypIPv4:
            return ipv4Target(in: data)
        case atypDomain:
            return domainTarget(in: data)
        case atypIPv6:
            return ipv6Target(in: data)
        default:
            return .failure(.invalid)
        }
    }

    static func isListenAddress(_ target: Target, port: UInt16) -> Bool {
        guard target.port == port else { return false }
        let host = target.host.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1"
    }
}

private extension Socks5Protocol {
    static func ipv4Target(in data: Data) -> Result<(Target, Int), ParseError> {
        let length = 10
        guard data.count >= length else { return .failure(.incomplete) }
        let host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
        return .success((Target(host: host, port: port(in: data, at: 8)), length))
    }

    static func domainTarget(in data: Data) -> Result<(Target, Int), ParseError> {
        let nameLength = Int(data[4])
        let length = 5 + nameLength + 2
        guard data.count >= length else { return .failure(.incomplete) }
        let nameData = data.subdata(in: 5..<(5 + nameLength))
        guard let host = String(data: nameData, encoding: .utf8), !host.isEmpty else {
            return .failure(.invalid)
        }
        return .success((Target(host: host, port: port(in: data, at: 5 + nameLength)), length))
    }

    static func ipv6Target(in data: Data) -> Result<(Target, Int), ParseError> {
        let length = 22
        guard data.count >= length else { return .failure(.incomplete) }
        let bytes = [UInt8](data.subdata(in: 4..<20))
        let groups = stride(from: 0, to: 16, by: 2).map { index -> String in
            String(format: "%x", UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }
        return .success((Target(host: groups.joined(separator: ":"), port: port(in: data, at: 20)), length))
    }

    static func port(in data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }
}
