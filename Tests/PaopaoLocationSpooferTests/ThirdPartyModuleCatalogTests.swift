import XCTest
@testable import PaopaoLocationSpoofer

final class ThirdPartyModuleCatalogTests: XCTestCase {
    func testSubscriptionURLsMatchDistribution() {
        XCTAssertEqual(
            ThirdPartyProxyClient.shadowrocket.subscriptionURL(for: .onDevice).absoluteString,
            "http://127.0.0.1:18766/modules/wloc.module"
        )
        XCTAssertEqual(
            ThirdPartyProxyClient.stash.subscriptionURL(for: .remoteMirror).absoluteString,
            "https://gh-proxy.org/https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/wloc.stoverride"
        )
        XCTAssertEqual(
            ThirdPartyProxyClient.quantumultX.subscriptionURL(for: .remoteDirect).absoluteString,
            "https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/wloc.conf"
        )
        XCTAssertEqual(
            ThirdPartyProxyClient.egern.subscriptionURL(for: .onDevice),
            ThirdPartyProxyClient.surge.subscriptionURL(for: .onDevice)
        )
    }

    func testRewriteSwitchesScriptPathsToLocalhost() throws {
        let root = try repositoryScriptsRoot()
        let rewritten = try ThirdPartyModuleCatalog.loadModule(
            root: root,
            fileName: "wloc.module",
            scriptBase: ThirdPartyModuleCatalog.localScriptBase
        )
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:18766/dist/v1/wloc.js"))
        XCTAssertTrue(rewritten.contains("http://127.0.0.1:18766/dist/v1/wloc-settings.js"))
        XCTAssertFalse(rewritten.contains("Yu9191/wloc"))
        XCTAssertFalse(rewritten.contains("raw.githubusercontent.com"))
    }

    func testHTTPServesRewrittenModuleAndRejectsUnknownPaths() throws {
        let root = try repositoryScriptsRoot()
        let module = ThirdPartyModuleHTTP.response(
            for: "GET /modules/wloc.module HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            root: root
        )
        XCTAssertEqual(module.status, 200)
        let text = String(data: module.body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("http://127.0.0.1:18766/dist/v1/wloc.js"))

        let health = ThirdPartyModuleHTTP.response(
            for: "GET /health HTTP/1.1\r\n\r\n",
            root: root
        )
        XCTAssertEqual(health.status, 200)
        XCTAssertEqual(String(data: health.body, encoding: .utf8), "ok")

        let missing = ThirdPartyModuleHTTP.response(
            for: "GET /../Secret.swift HTTP/1.1\r\n\r\n",
            root: root
        )
        XCTAssertEqual(missing.status, 400)
    }

    func testExportIncludesModuleAndScripts() throws {
        let root = try repositoryScriptsRoot()
        let urls = try ThirdPartyModuleCatalog.exportOnDeviceFiles(
            moduleFileName: "wloc.module",
            root: root
        )
        XCTAssertEqual(urls.map(\.lastPathComponent), ["wloc.module", "wloc.js", "wloc-settings.js"])
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func repositoryScriptsRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = directory.appendingPathComponent("ThirdParty/WlocScripts", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("repository WlocScripts folder is not reachable from this test file")
    }
}
