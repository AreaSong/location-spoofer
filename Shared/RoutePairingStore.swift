import Foundation

enum RoutePairingImportError: Error, Equatable {
    case invalidContents
}

/// 配对文件是设备的开发者信任凭证：只在首次解锁后可读，且不进入 iCloud / 电脑备份。
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

    var isExcludedFromBackup: Bool {
        (try? pairingURL.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    func install(_ data: Data) throws {
        guard Self.looksLikePairingPlist(data) else {
            throw RoutePairingImportError.invalidContents
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingURL.path)
        try Self.excludeFromBackup(directoryURL)
        try Self.excludeFromBackup(pairingURL)
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

    private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RoutePairing", isDirectory: true)
    }
}
