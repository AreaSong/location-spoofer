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
        let saved = try store.save(sample(name: "学校", latitude: 22.49))
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
        try destination.save(saved)
        let result = destination.importTransferred(decoded)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(destination.routes.count, 1)
        XCTAssertEqual(destination.routes[0].name, "操场")
        XCTAssertEqual(destination.routes[0].id, saved.id)
    }

    func testRecentRoutesCapAndDedup() throws {
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

    func testFailedImportReplacementPreservesSameIDAndGeometryMatchedID() throws {
        for matchByGeometry in [false, true] {
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defer { try? FileManager.default.removeItem(at: directory) }
            var failing = false
            let store = SavedRouteStore(defaults: defaults, pathDirectory: directory, beforePathWrite: { _ in
                if failing { throw CocoaError(.fileWriteOutOfSpace) }
            })
            let original = try store.save(sample(name: "原路线", latitude: 22.49))
            let catalog = defaults.data(forKey: "saved_routes_v1")
            let file = directory.appendingPathComponent("\(original.id).json")
            let path = try Data(contentsOf: file)
            var incoming = matchByGeometry ? sample(name: "新路线", latitude: 22.49) : original
            incoming.name = "新路线"
            incoming.pathPoints = [incoming.start,
                CoordinateConverter.coordinatePair(lat: 22.495, lon: 113.97, mapCoordinateSystem: .wgs84), incoming.end]
            incoming.createdAt = original.createdAt.addingTimeInterval(60)
            failing = true
            let result = store.importTransferred([incoming])
            XCTAssertEqual(result, .init(added: 0, updated: 0, skippedOverLimit: 0, failed: 1))
            XCTAssertEqual(result.title, "路线导入失败")
            XCTAssertEqual(store.routes, [original])
            XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), catalog)
            XCTAssertEqual(try Data(contentsOf: file), path)
            XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: directory).routes, [original])
            failing = false
            XCTAssertEqual(store.importTransferred([incoming]).updated, 1)
            let reloaded = SavedRouteStore(defaults: defaults, pathDirectory: directory)
            XCTAssertEqual(reloaded.routes.first?.id, original.id)
            XCTAssertEqual(reloaded.routes.first?.createdAt, matchByGeometry ? original.createdAt : incoming.createdAt)
            XCTAssertEqual(reloaded.routes.first?.pathPoints, incoming.pathPoints)
            XCTAssertEqual(reloaded.routes.first?.name, incoming.name)
            XCTAssertEqual(try RouteTransfer.decode(reloaded.exportTransferred()).first?.pathPoints, incoming.pathPoints)
        }
    }

    func testPartialImportCountsOnlyCommittedItemsAndReloads() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = sample(name: "失败", latitude: 24)
        let store = SavedRouteStore(defaults: defaults, pathDirectory: directory, beforePathWrite: { id in
            if id == failed.id { throw CocoaError(.fileWriteOutOfSpace) }
        })
        var updated = try store.save(sample(name: "已有", latitude: 22))
        updated.name = "更新成功"
        let added = sample(name: "新增成功", latitude: 23)
        let result = store.importTransferred([failed, added, updated])
        XCTAssertEqual(result, .init(added: 1, updated: 1, skippedOverLimit: 0, failed: 1))
        XCTAssertEqual(result.title, "路线部分导入")
        XCTAssertEqual(result.message, "新增 1 条，更新 1 条，超出上限 0 条，失败 1 条")
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: directory).routes, [added, updated])
    }

    func testImportAtLimitSkipsNewButStillUpdatesExisting() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let items = (0..<SavedRouteStore.limit).map { sample(name: "路线 \($0)", latitude: 20 + Double($0) * 0.01) }
        XCTAssertEqual(store.importTransferred(items).added, SavedRouteStore.limit)
        var updated = items[0]
        updated.name = "更新"
        let result = store.importTransferred([sample(name: "超限", latitude: 30), updated])
        XCTAssertEqual(result, .init(added: 0, updated: 1, skippedOverLimit: 1))
        let reloaded = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        XCTAssertEqual(reloaded.routes.count, SavedRouteStore.limit)
        XCTAssertEqual(reloaded.routes.last, updated)
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
