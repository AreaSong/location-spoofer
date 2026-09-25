import XCTest
@testable import PaopaoLocationSpoofer

final class SavedRouteStoreTests: XCTestCase {
    func testSavingPersistsAcrossStoreInstances() {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedRouteStore(defaults: defaults)
        let saved = store.save(sampleRoute(name: "学校"))
        XCTAssertEqual(store.routes.count, 1)
        let restored = SavedRouteStore(defaults: defaults).routes.first!
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.repeatMode, .roundTrip)
        XCTAssertEqual(restored.pathPoints!.count, 2)
        XCTAssertEqual(restored.viaPoints.count, 1)
        XCTAssertNil(restored.straightFallback)
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
