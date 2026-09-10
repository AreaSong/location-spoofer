import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyProxyManagerTests: XCTestCase {
    func testQueryDistinguishesConnectedWithoutCoordinate() async throws {
        let requester = FakeThirdPartyRequester(body: #"{"success":false,"error":"无已保存的坐标"}"#)
        let manager = ThirdPartyProxyManager(requester: requester)

        let response = try await manager.query()

        XCTAssertFalse(response.success)
        XCTAssertEqual(manager.connectionState, .connected(active: false))
        XCTAssertEqual(requester.lastURL?.query, "action=query")
    }

    func testSaveUsesFavoriteWGS84AndAcceptsMatchingResponse() async throws {
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .gcj02
        )
        let wgs84 = favorite.coordinatePair.wgs84
        let body = String(format: #"{"success":true,"longitude":%.8f,"latitude":%.8f,"accuracy":20}"#,
                          locale: Locale(identifier: "en_US_POSIX"), wgs84.longitude, wgs84.latitude)
        let requester = FakeThirdPartyRequester(body: body)
        let manager = ThirdPartyProxyManager(requester: requester, randomRadiusMeters: { 0 })

        _ = try await manager.save(favorite)

        let components = URLComponents(url: try XCTUnwrap(requester.lastURL), resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let latitude = try XCTUnwrap(Double(values["lat"] ?? ""))
        let longitude = try XCTUnwrap(Double(values["lon"] ?? ""))
        XCTAssertEqual(latitude, wgs84.latitude, accuracy: 0.000_000_01)
        XCTAssertEqual(longitude, wgs84.longitude, accuracy: 0.000_000_01)
        XCTAssertEqual(values["acc"], "20")
        XCTAssertEqual(values["randomRadius"], "0")
        XCTAssertEqual(manager.connectionState, .connected(active: true))
    }

    func testSaveForwardsConfiguredRandomRadius() async throws {
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 15,
            mapCoordinateSystem: .gcj02
        )
        let wgs84 = favorite.coordinatePair.wgs84
        let body = String(format: #"{"success":true,"longitude":%.8f,"latitude":%.8f,"accuracy":15}"#,
                          locale: Locale(identifier: "en_US_POSIX"), wgs84.longitude, wgs84.latitude)
        let requester = FakeThirdPartyRequester(body: body)
        let manager = ThirdPartyProxyManager(requester: requester, randomRadiusMeters: { 50 })

        _ = try await manager.save(favorite)

        let components = URLComponents(url: try XCTUnwrap(requester.lastURL), resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["randomRadius"], "50")
        XCTAssertEqual(values["acc"], "15")
    }

    func testSaveExplicitRandomRadiusOverridesStore() async throws {
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 15,
            mapCoordinateSystem: .gcj02
        )
        let wgs84 = favorite.coordinatePair.wgs84
        let body = String(format: #"{"success":true,"longitude":%.8f,"latitude":%.8f,"accuracy":15}"#,
                          locale: Locale(identifier: "en_US_POSIX"), wgs84.longitude, wgs84.latitude)
        let requester = FakeThirdPartyRequester(body: body)
        let manager = ThirdPartyProxyManager(requester: requester, randomRadiusMeters: { 50 })

        _ = try await manager.save(favorite, randomRadius: 0)

        let components = URLComponents(url: try XCTUnwrap(requester.lastURL), resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["randomRadius"], "0")
        XCTAssertEqual(values["acc"], "15")
    }

    func testConnectionUsesLegacySaveQueryEndpoint() async throws {
        let requester = FakeThirdPartyRequester(body: #"{"success":false,"error":"无已保存的坐标"}"#)
        let manager = ThirdPartyProxyManager(requester: requester)

        let response = try await manager.query()

        XCTAssertFalse(response.success)
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/save"])
        XCTAssertEqual(requester.requestedURLs.first?.query, "action=query")
    }

    func testLegacyModuleCanStillSaveBasicCoordinates() async throws {
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .gcj02
        )
        let wgs84 = favorite.coordinatePair.wgs84
        let body = String(
            format: #"{"success":true,"longitude":%.8f,"latitude":%.8f,"accuracy":20}"#,
            locale: Locale(identifier: "en_US_POSIX"),
            wgs84.longitude,
            wgs84.latitude
        )
        let requester = FakeThirdPartyRequester(body: body)
        let manager = ThirdPartyProxyManager(requester: requester, randomRadiusMeters: { 0 })

        let response = try await manager.save(favorite)

        XCTAssertTrue(response.success)
        XCTAssertEqual(manager.connectionState, .connected(active: true))
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/save"])
        let queryComponents = URLComponents(
            url: try XCTUnwrap(requester.requestedURLs.first),
            resolvingAgainstBaseURL: false
        )
        let values = Dictionary(
            uniqueKeysWithValues: (queryComponents?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(values["lon"], String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), wgs84.longitude))
        XCTAssertEqual(values["lat"], String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), wgs84.latitude))
        XCTAssertEqual(values["acc"], "20")
        XCTAssertEqual(values["randomRadius"], "0")
    }

    func testBrokenSaveQueryFailsWithoutCheckingVersion() async {
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester)

        do {
            _ = try await manager.query()
            XCTFail("expected interception failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .moduleNotIntercepted)
        }
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/save"])
    }

    func testSaveRejectsCoordinateMismatchWithoutMarkingActive() async {
        let requester = FakeThirdPartyRequester(body: #"{"success":true,"longitude":1,"latitude":2,"accuracy":25}"#)
        let manager = ThirdPartyProxyManager(requester: requester)
        let favorite = FavoriteLocation(name: "深圳湾", latitude: 22.494, longitude: 113.951, accuracy: 25)

        do {
            _ = try await manager.save(favorite)
            XCTFail("expected coordinate mismatch")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .coordinateMismatch)
        }
        XCTAssertEqual(manager.connectionState, .unknown)
        XCTAssertNil(manager.activeSettings)
    }

    func testMalformedResponseIsNotTreatedAsSuccess() async {
        let manager = ThirdPartyProxyManager(requester: FakeThirdPartyRequester(body: "not-json"))
        do {
            _ = try await manager.query()
            XCTFail("expected interception failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .moduleNotIntercepted)
        }
    }

    func testNonHTTP200IsTreatedAsModuleNotIntercepted() async {
        let requester = FakeThirdPartyRequester(body: #"{"success":true}"#, statusCode: 404)
        let manager = ThirdPartyProxyManager(requester: requester)

        do {
            _ = try await manager.query()
            XCTFail("expected interception failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .moduleNotIntercepted)
            XCTAssertEqual(manager.connectionState, .failed("模块没有拦住请求"))
        }
    }

    func testCertificateTrustErrorIsClassified() async {
        let requester = FakeThirdPartyRequester(error: URLError(.serverCertificateUntrusted))
        let manager = ThirdPartyProxyManager(requester: requester)

        do {
            _ = try await manager.query()
            XCTFail("expected certificate failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .certificateUntrusted)
            XCTAssertEqual(manager.connectionState, .failed("证书未完全信任"))
            XCTAssertFalse(error.localizedDescription.contains("错误代码"))
        }
    }

    func testTimeoutIsClassifiedAsProxyNotConnected() async {
        let requester = FakeThirdPartyRequester(error: URLError(.timedOut))
        let manager = ThirdPartyProxyManager(requester: requester)

        do {
            _ = try await manager.query()
            XCTFail("expected connectivity failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .proxyNotConnected)
            XCTAssertEqual(manager.connectionState, .failed("代理未连上"))
        }
    }

    func testClientLinksUseVendoredModulesAndVerificationLabels() {
        XCTAssertEqual(
            ThirdPartyProxyManager.interceptionHostnamesText,
            "gs-loc.apple.com, gs-loc-cn.apple.com, gsp-ssl.ls.apple.com, bluedot.is.autonavi.com, bluedot.is.autonavi.com.gds.alibabadns.com"
        )
        XCTAssertNil(ThirdPartyProxyClient.shadowrocket.verificationText)
        XCTAssertTrue(ThirdPartyProxyClient.surge.verificationText?.contains("尚未验证") == true)
        XCTAssertEqual(
            ThirdPartyProxyClient.egern.subscriptionURL(for: .remoteMirror),
            ThirdPartyProxyClient.surge.subscriptionURL(for: .remoteMirror)
        )
        XCTAssertTrue(ThirdPartyProxyClient.stash.subscriptionURL(for: .remoteMirror).absoluteString.hasPrefix(
            "https://gh-proxy.org/https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/"
        ))
        let stashComponents = URLComponents(
            url: ThirdPartyProxyClient.stash.subscriptionURL(for: .remoteMirror),
            resolvingAgainstBaseURL: false
        )
        let shadowrocketComponents = URLComponents(
            url: ThirdPartyProxyClient.shadowrocket.subscriptionURL(for: .onDevice),
            resolvingAgainstBaseURL: false
        )
        XCTAssertEqual(stashComponents?.path, "/https://raw.githubusercontent.com/AreaSong/location-spoofer/main/ThirdParty/WlocScripts/modules/wloc.stoverride")
        XCTAssertEqual(shadowrocketComponents?.host, "127.0.0.1")
        XCTAssertEqual(shadowrocketComponents?.path, "/modules/wloc.module")
        XCTAssertTrue(stashComponents?.queryItems?.isEmpty ?? true)
        XCTAssertTrue(shadowrocketComponents?.queryItems?.isEmpty ?? true)
        XCTAssertEqual(ThirdPartyProxyClient.shadowrocket.launchURL?.scheme, "shadowrocket")
        XCTAssertEqual(ThirdPartyProxyClient.surge.launchURL?.scheme, "surge")
        XCTAssertEqual(ThirdPartyProxyClient.quantumultX.launchURL?.scheme, "quantumult-x")
        XCTAssertEqual(ThirdPartyProxyClient.loon.launchURL?.scheme, "loon")
        XCTAssertEqual(ThirdPartyProxyClient.stash.launchURL?.scheme, "stash")
        XCTAssertEqual(ThirdPartyProxyClient.egern.launchURL?.scheme, "egern")
    }

    func testSelectedClientPersists() {
        let suiteName = "ThirdPartyProxyClientStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThirdPartyProxyClientStore(defaults: defaults)
        XCTAssertEqual(store.selectedClient, .shadowrocket)

        store.select(.stash)
        XCTAssertEqual(ThirdPartyProxyClientStore(defaults: defaults).selectedClient, .stash)
    }
}

private final class FakeThirdPartyRequester: ThirdPartyProxyRequesting {
    private let data: Data
    private let statusCode: Int
    private let transportError: Error?
    private(set) var lastURL: URL?
    private(set) var requestedURLs: [URL] = []

    init(body: String, statusCode: Int = 200) {
        data = Data(body.utf8)
        self.statusCode = statusCode
        transportError = nil
    }

    init(error: Error) {
        data = Data()
        statusCode = 0
        transportError = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastURL = request.url
        requestedURLs.append(request.url!)
        if let transportError {
            throw transportError
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
