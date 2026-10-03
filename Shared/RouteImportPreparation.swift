import Foundation

/// 仅处理输入值，不捕获 Store、页面或剪贴板。所有解析对象均由本轮调用独占。
enum RouteImportPreparation {
    enum Input { case file(URL), clipboard(String) }
    enum Stage: Equatable {
        case beforeRead, afterRead, decoding, parsing, converting
        case simplifying(Int), simplificationStep, prepared
    }

    struct FileAccess {
        var begin: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var end: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    }

    struct Prepared {
        let routes: [SavedRoute]
        // 只能由完整解码和简化链路构造；提交仍走 Store 的全部校验和原子写入。
        fileprivate init(routes: [SavedRoute]) { self.routes = routes }
    }

    static func prepare(
        _ input: Input,
        access: FileAccess = FileAccess(),
        checkpoint: @escaping (Stage) throws -> Void = { _ in try Task.checkCancellation() }
    ) throws -> Prepared {
        try checkpoint(.beforeRead)
        let data: Data
        let name: String
        switch input {
        case .file(let url):
            data = try readFile(url, access: access)
            name = url.deletingPathExtension().lastPathComponent
        case .clipboard(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipboardError.empty
            }
            data = Data(text.utf8)
            name = "导入路线"
        }
        try checkpoint(.afterRead)
        let routes = try decode(data, name: name, checkpoint: checkpoint)
        try checkpoint(.prepared)
        return Prepared(routes: routes)
    }

    private static func decode(
        _ data: Data, name: String, checkpoint: @escaping (Stage) throws -> Void
    ) throws -> [SavedRoute] {
        try checkpoint(.decoding)
        if RouteGPX.looksLikeGPX(data) {
            return try RouteGPX.decode(data, fallbackName: name, checkpoint: checkpoint)
        }
        if RouteKML.looksLikeKMZ(data) { throw RouteKML.ParseError.unsupportedArchive }
        if RouteKML.looksLikeKML(data) {
            return try RouteKML.decode(data, fallbackName: name, checkpoint: checkpoint)
        }
        let routes: [SavedRoute]
        do {
            routes = try RouteTransfer.decode(data) { try checkpoint(.converting) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 保留原内容探测顺序及 JSON 错误；取消不能被格式回退吞掉。
            let jsonError = error
            do { return try RouteGPX.decode(data, fallbackName: name, checkpoint: checkpoint) }
            catch is CancellationError { throw CancellationError() }
            catch {}
            do { return try RouteKML.decode(data, fallbackName: name, checkpoint: checkpoint) }
            catch is CancellationError { throw CancellationError() }
            catch {}
            throw jsonError
        }
        return try routes.map { route in
            var prepared = route
            if let points = route.pathPoints {
                try checkpoint(.simplifying(points.count))
                prepared.pathPoints = try RoutePathSimplifier.simplify(points) {
                    try checkpoint(.simplificationStep)
                }
            }
            return prepared
        }
    }

    private static func readFile(_ url: URL, access: FileAccess) throws -> Data {
        let accessing = access.begin(url)
        defer { if accessing { access.end(url) } }
        // 文件提供方读取可能不可中断；返回后检查失效，访问权不延长到解析或提交。
        return try access.read(url)
    }

    private enum ClipboardError: LocalizedError {
        case empty
        var errorDescription: String? { "剪贴板里没有路线备份" }
    }
}
