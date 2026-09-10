import Foundation

enum ThirdPartyModuleDistribution: String, CaseIterable, Identifiable {
    case onDevice
    case remoteMirror
    case remoteDirect

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "本机"
        case .remoteMirror: return "GitHub 镜像"
        case .remoteDirect: return "GitHub 直连"
        }
    }
}

enum ThirdPartyModuleCatalogError: LocalizedError {
    case bundleMissing
    case unknownPath
    case unreadable

    var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return "本机模块文件缺失，请重新安装 App"
        case .unknownPath:
            return "未知的模块路径"
        case .unreadable:
            return "无法读取本机模块文件"
        }
    }
}

enum ThirdPartyModuleCatalog {
    static let port: UInt16 = 18_766
    static let folderName = "WlocScripts"
    static let remoteRepositoryPath =
        "https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts"
    static let moduleFileNames = [
        "wloc.module",
        "wloc.sgmodule",
        "wloc.conf",
        "wloc.lpx",
        "wloc.stoverride"
    ]

    static var localBaseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    static var localScriptBase: String {
        "\(localBaseURL.absoluteString)/dist/v1"
    }

    static let allowedPaths: Set<String> = {
        var paths: Set<String> = [
            "/health",
            "/dist/v1/wloc.js",
            "/dist/v1/wloc-settings.js"
        ]
        for name in moduleFileNames {
            paths.insert("/modules/\(name)")
        }
        return paths
    }()

    static func bundledRoot(in bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: folderName, withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let resource = bundle.resourceURL {
            let folder = resource.appendingPathComponent(folderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                return folder
            }
        }
        return nil
    }

    static func subscriptionURL(
        moduleFileName: String,
        distribution: ThirdPartyModuleDistribution
    ) -> URL {
        switch distribution {
        case .onDevice:
            return localBaseURL
                .appendingPathComponent("modules")
                .appendingPathComponent(moduleFileName)
        case .remoteMirror, .remoteDirect:
            let path = "\(remoteRepositoryPath)/modules/\(moduleFileName)"
            let value = distribution == .remoteMirror ? "https://gh-proxy.org/\(path)" : path
            return URL(string: value)!
        }
    }

    static func scriptBase(for distribution: ThirdPartyModuleDistribution) -> String {
        switch distribution {
        case .onDevice:
            return localScriptBase
        case .remoteMirror:
            return "https://gh-proxy.org/\(remoteRepositoryPath)/dist/v1"
        case .remoteDirect:
            return "\(remoteRepositoryPath)/dist/v1"
        }
    }

    static func rewriteScriptPaths(_ text: String, to scriptBase: String) -> String {
        var result = text
        let sources = [
            "https://gh-proxy.org/\(remoteRepositoryPath)/dist/v1",
            "\(remoteRepositoryPath)/dist/v1",
            localScriptBase
        ]
        for source in sources where source != scriptBase {
            result = result.replacingOccurrences(of: source, with: scriptBase)
        }
        return result
    }

    static func fileURL(root: URL, relativePath: String) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").reduce(root) { partial, part in
            partial.appendingPathComponent(String(part))
        }
    }

    static func loadFile(root: URL, relativePath: String) throws -> Data {
        let url = fileURL(root: root, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThirdPartyModuleCatalogError.unreadable
        }
        return try Data(contentsOf: url)
    }

    static func loadModule(root: URL, fileName: String, scriptBase: String) throws -> String {
        let data = try loadFile(root: root, relativePath: "modules/\(fileName)")
        guard let text = String(data: data, encoding: .utf8) else {
            throw ThirdPartyModuleCatalogError.unreadable
        }
        return rewriteScriptPaths(text, to: scriptBase)
    }

    static func exportOnDeviceFiles(moduleFileName: String, root: URL) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WlocOnDevice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let moduleText = try loadModule(
            root: root,
            fileName: moduleFileName,
            scriptBase: localScriptBase
        )
        let moduleURL = directory.appendingPathComponent(moduleFileName)
        try moduleText.write(to: moduleURL, atomically: true, encoding: .utf8)
        var urls = [moduleURL]
        for script in ["wloc.js", "wloc-settings.js"] {
            let data = try loadFile(root: root, relativePath: "dist/v1/\(script)")
            let url = directory.appendingPathComponent(script)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }
}

enum ThirdPartyModuleHTTP {
    static func response(for request: String, root: URL) -> (status: Int, headers: [String: String], body: Data) {
        guard let target = requestLineTarget(request) else {
            return http(status: 400, contentType: "text/plain", body: Data("bad request".utf8))
        }
        let method = requestLineMethod(request)
        if method != "GET" && method != "HEAD" {
            return http(status: 405, contentType: "text/plain", body: Data("method not allowed".utf8))
        }
        guard let path = normalizedPath(target) else {
            return http(status: 400, contentType: "text/plain", body: Data("bad path".utf8))
        }
        if path == "/health" {
            return http(status: 200, contentType: "text/plain", body: Data("ok".utf8), includeBody: method == "GET")
        }
        guard ThirdPartyModuleCatalog.allowedPaths.contains(path) else {
            return http(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
        do {
            let body = try bodyData(for: path, root: root)
            return http(
                status: 200,
                contentType: contentType(for: path),
                body: body,
                includeBody: method == "GET"
            )
        } catch {
            return http(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    static func encode(_ response: (status: Int, headers: [String: String], body: Data)) -> Data {
        let reason: [Int: String] = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"]
        var header = "HTTP/1.1 \(response.status) \(reason[response.status] ?? "Error")\r\n"
        for (key, value) in response.headers {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        return data
    }

    private static func requestLineMethod(_ request: String) -> String {
        String(request.split(whereSeparator: \.isNewline).first?.split(separator: " ").first ?? "")
    }

    private static func requestLineTarget(_ request: String) -> String? {
        let parts = request.split(whereSeparator: \.isNewline).first?.split(separator: " ")
        guard let parts, parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private static func normalizedPath(_ target: String) -> String? {
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? Substring(target))
        guard path.hasPrefix("/"), !path.contains("..") else { return nil }
        return path
    }

    private static func bodyData(for path: String, root: URL) throws -> Data {
        if path.hasPrefix("/modules/") {
            let fileName = String(path.dropFirst("/modules/".count))
            let text = try ThirdPartyModuleCatalog.loadModule(
                root: root,
                fileName: fileName,
                scriptBase: ThirdPartyModuleCatalog.localScriptBase
            )
            return Data(text.utf8)
        }
        return try ThirdPartyModuleCatalog.loadFile(root: root, relativePath: path)
    }

    private static func contentType(for path: String) -> String {
        path.hasSuffix(".js") ? "application/javascript; charset=utf-8" : "text/plain; charset=utf-8"
    }

    private static func http(
        status: Int,
        contentType: String,
        body: Data,
        includeBody: Bool = true
    ) -> (status: Int, headers: [String: String], body: Data) {
        (
            status,
            [
                "Content-Type": contentType,
                "Content-Length": String(body.count),
                "Connection": "close",
                "Cache-Control": "no-store"
            ],
            includeBody ? body : Data()
        )
    }
}
