import Foundation

enum RoutePairingImportError: Error, Equatable {
    case invalidContents
}

final class RoutePairingStore {
    static let fileName = "rp_pairing_file.plist"

    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
    }

    var pairingURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: pairingURL.path)
    }

    func install(_ data: Data) throws {
        guard Self.looksLikePairingPlist(data) else {
            throw RoutePairingImportError.invalidContents
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: pairingURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingURL.path)
    }

    func remove() throws {
        guard hasPairingFile else { return }
        try FileManager.default.removeItem(at: pairingURL)
    }

    static func looksLikePairingPlist(_ data: Data) -> Bool {
        if let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return object is [AnyHashable: Any] || object is [Any]
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return text.hasPrefix("<?xml") && text.contains("<plist") && text.contains("<dict>")
    }

    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RoutePairing", isDirectory: true)
    }
}
