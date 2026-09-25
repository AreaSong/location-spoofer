import XCTest
@testable import PaopaoLocationSpoofer

final class SavedRouteStoreTests: XCTestCase {
    func testSavingPersistsAcrossStoreInstances() {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedRouteStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let saved = store.save(sampleRoute(name: "学校"))
        XCTAssertEqual(store.routes.count, 1)
        let restored = SavedRouteStore(defaults: defaults, pathDirectory: directory).routes.first!
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.repeatMode, .roundTrip)
        XCTAssertEqual(restored.pathPoints!.count, 2)
        XCTAssertEqual(restored.viaPoints.count, 1)
        XCTAssertNil(restored.straightFallback)
        let catalog = String(data: defaults.data(forKey: "saved_routes_v1")!, encoding: .utf8)!
        XCTAssertFalse(catalog.contains("pathPoints"))
    }

    func testOldRouteWithoutFallbackDecodesAsNil() throws {
        let suite = "SavedRouteStoreTests.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = sampleRoute(name: "旧路线")
        let data = try JSONEncoder().encode([saved])
        var object = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        object[0].removeValue(forKey: "straightFallback")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        defaults.set(legacy, forKey: "saved_routes_v1")
        let restored = SavedRouteStore(defaults: defaults).routes.first
        XCTAssertEqual(restored?.name, "旧路线")
        XCTAssertNil(restored?.straightFallback)
    }

    func testStraightFallbackRoundTrips() {
        let suite = "SavedRouteStoreTests.fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var route = sampleRoute(name: "直线")
        route.straightFallback = .partial
        SavedRouteStore(defaults: defaults).save(route)
        XCTAssertEqual(SavedRouteStore(defaults: defaults).routes.first?.straightFallback, .partial)
        XCTAssertEqual(RoutePathFallback.partial.notice, "部分路段规划失败，已改用直线")
    }

    func testEmbeddedPathMigratesOutOfDefaultsAndCapsFilePoints() throws {
        let suite = "SavedRouteStoreTests.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var route = sampleRoute(name: "长路线")
        route.pathPoints = (0..<900).map { index in
            CoordinateConverter.coordinatePair(
                lat: 22.49 + Double(index) * 0.00001,
                lon: 113.95 + Double(index) * 0.00001,
                mapCoordinateSystem: .wgs84
            )
        }
        let encoded = try JSONEncoder().encode([route])
        var object = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        let points = route.pathPoints!.map {
            ["wgs84": ["latitude": $0.wgs84.latitude, "longitude": $0.wgs84.longitude],
             "gcj02": ["latitude": $0.gcj02.latitude, "longitude": $0.gcj02.longitude],
             "conversionVersion": 1]
        }
        object[0]["pathPoints"] = points
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "saved_routes_v1")

        let restored = SavedRouteStore(defaults: defaults, pathDirectory: directory).routes.first!
        XCTAssertLessThanOrEqual(restored.pathPoints!.count, RoutePathSimplifier.maxPoints)
        XCTAssertGreaterThanOrEqual(restored.pathPoints!.count, 2)
        let catalog = String(data: defaults.data(forKey: "saved_routes_v1")!, encoding: .utf8)!
        XCTAssertFalse(catalog.contains("pathPoints"))

        let file = directory.appendingPathComponent("\(route.id.uuidString).json")
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(SavedRouteStore(defaults: defaults, pathDirectory: directory).routes.first?.pathPoints)
    }

    func testSaveInsertsNewestFirstAndCapsAtLimit() {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults)
        var first: SavedRoute?
        for index in 0..<SavedRouteStore.limit + 3 {
            let saved = store.save(sampleRoute(name: "路线 \(index)"))
            if index == 0 { first = saved }
        }
        XCTAssertEqual(store.routes.count, SavedRouteStore.limit)
        XCTAssertEqual(store.routes.first!.name, "路线 \(SavedRouteStore.limit + 2)")
        XCTAssertFalse(store.routes.contains(where: { $0.id == first!.id }))
    }

    func testSavingSameIDReplacesExistingRoute() {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults)
        let saved = store.save(sampleRoute(name: "学校"))
        var updated = saved
        updated.name = "操场"
        store.save(updated)
        XCTAssertEqual(store.routes.count, 1)
        XCTAssertEqual(store.routes.first!.id, saved.id)
        XCTAssertEqual(store.routes.first!.name, "操场")
    }

    func testRenameAndDeletePersist() {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults)
        let saved = store.save(sampleRoute(name: "学校"))
        store.rename(saved.id, to: "操场")
        XCTAssertEqual(SavedRouteStore(defaults: defaults).routes.first!.name, "操场")
        store.delete(saved)
        XCTAssertTrue(SavedRouteStore(defaults: defaults).routes.isEmpty)
    }

    private func sampleRoute(name: String) -> SavedRoute {
        let start = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )
        let end = CoordinateConverter.coordinatePair(
            lat: 22.495,
            lon: 113.952,
            mapCoordinateSystem: .wgs84
        )
        let via = CoordinateConverter.coordinatePair(
            lat: 22.4945,
            lon: 113.9515,
            mapCoordinateSystem: .wgs84
        )
        return SavedRoute(
            name: name,
            start: start,
            end: end,
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .roundTrip,
            viaPoints: [via],
            pathPoints: [start, end]
        )
    }
}
