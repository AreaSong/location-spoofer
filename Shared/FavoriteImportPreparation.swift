import Foundation

/// 仅捕获输入值；此层不接触 Store、剪贴板或页面状态。
enum FavoriteImportPreparation {
    enum Input {
        case file(URL)
        case clipboard(String)
    }

    enum Stage { case beforeRead, afterRead, decoding, converting, deduplicating, prepared }

    struct FileAccess {
        var begin: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var end: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    }

    static func prepare(
        _ input: Input,
        access: FileAccess = FileAccess(),
        checkpoint: (Stage) throws -> Void = { _ in try Task.checkCancellation() }
    ) throws -> FavoriteTransfer.Prepared {
        try checkpoint(.beforeRead)
        let data: Data
        switch input {
        case .file(let url): data = try readFile(url, access: access)
        case .clipboard(let text): data = Data(text.utf8)
        }
        try checkpoint(.afterRead)
        try checkpoint(.decoding)
        let incoming = try FavoriteTransfer.decode(data) { try checkpoint(.converting) }
        let prepared = try FavoriteTransfer.prepare(incoming) { try checkpoint(.deduplicating) }
        try checkpoint(.prepared)
        return prepared
    }

    private static func readFile(_ url: URL, access: FileAccess) throws -> Data {
        let accessing = access.begin(url)
        defer { if accessing { access.end(url) } }
        // 同步提供方 I/O 不保证可中断；访问权只覆盖读取，不覆盖解析和提交。
        return try access.read(url)
    }
}
