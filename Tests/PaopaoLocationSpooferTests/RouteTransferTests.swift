import XCTest
@testable import PaopaoLocationSpoofer

final class RouteTransferTests: XCTestCase {
    func testExportImportMergesByGeometryAndOmitsCatalogPath() throws {
        let suite = "RouteTransferTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let saved = store.save(sample(name: "学校", latitude: 22.49))
        let exported = try store.exportTransferred()
        XCTAssertFalse(String(data: defaults.data(forKey: "saved_routes_v1")!, encoding: .utf8)!.contains("pathPoints"))

        let otherDefaults = UserDefaults(suiteName: suite + ".dest")!
        defer { otherDefaults.removePersistentDomain(forName: suite + ".dest") }
        let destination = SavedRouteStore(defaults: otherDefaults, pathDirectory: directory.appendingPathComponent("dest"))
        var decoded = try RouteTransfer.decode(exported)
        decoded[0] = SavedRoute(
            id: UUID(),
            name: "操场",
            start: decoded[0].start,
            end: decoded[0].end,
            travelMode: decoded[0].travelMode,
            speedKilometersPerHour: decoded[0].speedKilometersPerHour,
            offsetMeters: decoded[0].offsetMeters,
            repeatMode: decoded[0].repeatMode,
            viaPoints: decoded[0].viaPoints,
            pathPoints: decoded[0].pathPoints,
            createdAt: decoded[0].createdAt
        )
        destination.save(saved)
        let result = destination.importTransferred(decoded)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(destination.routes.count, 1)
        XCTAssertEqual(destination.routes[0].name, "操场")
        XCTAssertEqual(destination.routes[0].id, saved.id)
    }

    func testRecentRoutesCapAndDedup() {
        let suite = "RecentRouteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentRouteStore(defaults: defaults)
        let first = sample(name: "第一条", latitude: 22.49)
        store.record(route: first)
        store.record(route: first)
        XCTAssertEqual(store.routes.count, 1)
        for index in 0..<RecentRouteStore.limit {
            store.record(route: sample(name: "路线 \(index)", latitude: 23 + Double(index) * 0.01))
        }
        XCTAssertEqual(store.routes.count, RecentRouteStore.limit)
        XCTAssertFalse(store.routes.contains { $0.name == "第一条" })
    }

    private func sample(name: String, latitude: Double) -> SavedRoute {
        let start = CoordinateConverter.coordinatePair(lat: latitude, lon: 113.95, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: latitude + 0.01, lon: 113.96, mapCoordinateSystem: .wgs84)
        return SavedRoute(
            name: name,
            start: start,
            end: end,
            travelMode: .walk,
            speedKilometersPerHour: 5,
            offsetMeters: 0,
            repeatMode: .once,
            viaPoints: [],
            pathPoints: [start, end]
        )
    }
}

private extension RecentRouteStore {
    func record(route: SavedRoute) {
        record(
            name: route.name,
            start: route.start,
            end: route.end,
            viaPoints: route.viaPoints,
            travelMode: route.travelMode,
            speedKilometersPerHour: route.speedKilometersPerHour,
            offsetMeters: route.offsetMeters,
            repeatMode: route.repeatMode
        )
    }
}
