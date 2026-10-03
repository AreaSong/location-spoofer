import XCTest
@testable import PaopaoLocationSpoofer

final class SavedRouteStoreTests: XCTestCase {
    private var isolatedDirectory: URL!

    override func setUpWithError() throws {
        isolatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: isolatedDirectory.path) {
            try FileManager.default.removeItem(at: isolatedDirectory)
        }
    }

    func testSavingPersistsAcrossStoreInstances() throws {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedRouteStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let saved = try store.save(sampleRoute(name: "学校"))
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
        let restored = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.first
        XCTAssertEqual(restored?.name, "旧路线")
        XCTAssertNil(restored?.straightFallback)
    }

    func testStraightFallbackRoundTrips() throws {
        let suite = "SavedRouteStoreTests.fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var route = sampleRoute(name: "直线")
        route.straightFallback = .partial
        try SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).save(route)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.first?.straightFallback, .partial)
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

    func testSaveInsertsNewestFirstAndCapsAtLimit() throws {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        var first: SavedRoute?
        for index in 0..<SavedRouteStore.limit + 3 {
            let saved = try store.save(sampleRoute(name: "路线 \(index)"))
            if index == 0 { first = saved }
        }
        XCTAssertEqual(store.routes.count, SavedRouteStore.limit)
        XCTAssertEqual(store.routes.first!.name, "路线 \(SavedRouteStore.limit + 2)")
        XCTAssertFalse(store.routes.contains(where: { $0.id == first!.id }))
    }

    func testSavingSameIDReplacesExistingRoute() throws {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        let saved = try store.save(sampleRoute(name: "学校"))
        var updated = saved
        updated.name = "操场"
        try store.save(updated)
        XCTAssertEqual(store.routes.count, 1)
        XCTAssertEqual(store.routes.first!.id, saved.id)
        XCTAssertEqual(store.routes.first!.name, "操场")
    }

    func testRenameAndDeletePersist() throws {
        let suite = "SavedRouteStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        let saved = try store.save(sampleRoute(name: "学校"))
        try store.rename(saved.id, to: "操场")
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.first!.name, "操场")
        try store.delete(saved)
        XCTAssertTrue(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.isEmpty)
    }

    func testLegacyMigrationFailurePreservesOriginalCatalogAndRetries() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // 旧目录的实际字段布局；不经当前 SavedRoute.encode 构造夹具。
        let original = Data(#"""
        [{"id":"7B983438-E72D-47BE-9FD1-D3142D72AD77","name":"历史",
          "start":{"wgs84":{"latitude":1,"longitude":2},"gcj02":{"latitude":1,"longitude":2},"conversionVersion":1},
          "end":{"wgs84":{"latitude":1.01,"longitude":2.01},"gcj02":{"latitude":1.01,"longitude":2.01},"conversionVersion":1},
          "travelMode":"walk","speedKilometersPerHour":5,"offsetMeters":0,"repeatMode":"roundTrip","createdAt":100,
          "pathPoints":[
            {"wgs84":{"latitude":1,"longitude":2},"gcj02":{"latitude":1,"longitude":2},"conversionVersion":1},
            {"wgs84":{"latitude":1.01,"longitude":2.01},"gcj02":{"latitude":1.01,"longitude":2.01},"conversionVersion":1}
          ]}]
        """#.utf8)
        let route = try JSONDecoder().decode([SavedRoute].self, from: original)[0]
        defaults.set(original, forKey: "saved_routes_v1")
        // 确定性故障：目录位置放普通文件，不依赖权限或运行用户。
        try Data("blocked".utf8).write(to: isolatedDirectory)
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), original)
        XCTAssertEqual(store.routes.first?.pathPoints, route.pathPoints)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.first?.pathPoints, route.pathPoints)
        try FileManager.default.removeItem(at: isolatedDirectory)
        let recovered = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        XCTAssertEqual(recovered.routes.first?.pathPoints, route.pathPoints)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, recovered.routes)
    }

    func testFailedNewSaveDoesNotPublishOrPersist() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try Data("blocked".utf8).write(to: isolatedDirectory)
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        XCTAssertThrowsError(try store.save(sampleRoute(name: "失败")))
        XCTAssertTrue(store.routes.isEmpty)
        XCTAssertNil(defaults.data(forKey: "saved_routes_v1"))
        XCTAssertTrue(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.isEmpty)
    }

    func testFailedOverwriteAndCapacitySavePreserveCatalogAndPaths() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var failing = false
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory, beforePathWrite: { _ in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
        })
        for index in 0..<SavedRouteStore.limit {
            try store.save(sampleRoute(name: "路线 \(index)"))
        }
        let original = store.routes
        let catalog = defaults.data(forKey: "saved_routes_v1")
        let oldestFile = isolatedDirectory.appendingPathComponent("\(original.last!.id).json")
        let oldestData = try Data(contentsOf: oldestFile)
        let overwrittenFile = isolatedDirectory.appendingPathComponent("\(original[0].id).json")
        let overwrittenData = try Data(contentsOf: overwrittenFile)
        var updated = original[0]
        updated.name = "替换"
        updated.pathPoints = [updated.start, updated.viaPoints[0], updated.end]
        failing = true
        XCTAssertThrowsError(try store.save(updated))
        XCTAssertThrowsError(try store.save(sampleRoute(name: "新增失败")))
        XCTAssertEqual(store.routes, original)
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), catalog)
        XCTAssertEqual(try Data(contentsOf: oldestFile), oldestData)
        XCTAssertEqual(try Data(contentsOf: overwrittenFile), overwrittenData)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, original)
        failing = false
        try store.save(updated)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.first, updated)
        let added = try store.save(sampleRoute(name: "新增成功"))
        let reloaded = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        XCTAssertEqual(reloaded.routes.count, SavedRouteStore.limit)
        XCTAssertEqual(reloaded.routes.first, added)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestFile.path))
    }

    func testInvalidCatalogCannotReplaceExistingPath() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        let original = try store.save(sampleRoute(name: "原路线"))
        var invalid = original
        invalid.speedKilometersPerHour = .infinity
        invalid.pathPoints = [original.start, original.viaPoints[0], original.end]
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, [original])
    }

    func testPendingMigrationCannotBeErasedByOtherMutationsAndCanRetryInPlace() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = sampleRoute(name: "旧轨迹")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode([legacy])) as! [[String: Any]]
        object[0]["pathPoints"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy.pathPoints!))
        let original = try JSONSerialization.data(withJSONObject: object)
        defaults.set(original, forKey: "saved_routes_v1")
        var failing = true
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory, beforePathWrite: { _ in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
        })
        XCTAssertThrowsError(try store.rename(legacy.id, to: "改名"))
        XCTAssertThrowsError(try store.delete(legacy))
        XCTAssertThrowsError(try store.save(sampleRoute(name: "新增")))
        XCTAssertEqual(store.importTransferred([legacy]).failed, 1)
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), original)
        XCTAssertEqual(try RouteTransfer.decode(store.exportTransferred()).first?.pathPoints, legacy.pathPoints)
        failing = false
        try store.rename(legacy.id, to: "重试成功")
        let restored = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        XCTAssertEqual(restored.routes.first?.name, "重试成功")
        XCTAssertEqual(restored.routes.first?.pathPoints, legacy.pathPoints)
        XCTAssertFalse(String(data: defaults.data(forKey: "saved_routes_v1")!, encoding: .utf8)!.contains("pathPoints"))
    }

    func testRemovingPathDoesNotResurrectOldFileAfterReload() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        var route = try store.save(sampleRoute(name: "有路径"))
        route.pathPoints = nil
        try store.save(route)
        XCTAssertNil(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes.first?.pathPoints)
    }

    func testAtomicReplacementFailureLeavesDestinationAndCleansStagingFile() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = sampleRoute(name: "替换失败")
        let destination = isolatedDirectory.appendingPathComponent("\(route.id).json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("recoverable")
        try Data("original".utf8).write(to: marker)
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        // 暂存写入和回读可成功，最终 rename 因目标是非空目录而失败。
        XCTAssertThrowsError(try store.save(route))
        XCTAssertEqual(try Data(contentsOf: marker), Data("original".utf8))
        XCTAssertNil(defaults.data(forKey: "saved_routes_v1"))
        XCTAssertTrue(store.routes.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: isolatedDirectory.path), ["\(route.id).json"])
    }

    func testPartialLegacyMigrationPreservesAllEmbeddedRecoverySources() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = [sampleRoute(name: "第一条"), sampleRoute(name: "第二条")]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [[String: Any]]
        for index in legacy.indices {
            object[index]["pathPoints"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy[index].pathPoints!))
        }
        let original = try JSONSerialization.data(withJSONObject: object)
        defaults.set(original, forKey: "saved_routes_v1")
        var failing = true
        let failSecond: (UUID) throws -> Void = { id in
            if failing && id == legacy[1].id { throw CocoaError(.fileWriteOutOfSpace) }
        }
        let first = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory, beforePathWrite: failSecond)
        XCTAssertEqual(first.routes, legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedDirectory.appendingPathComponent("\(legacy[0].id).json").path))
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), original)
        let second = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory, beforePathWrite: failSecond)
        XCTAssertEqual(second.routes, legacy)
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), original)
        failing = false
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, legacy)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, legacy)
        XCTAssertFalse(String(data: defaults.data(forKey: "saved_routes_v1")!, encoding: .utf8)!.contains("pathPoints"))
    }

    func testPathRemovalFailureRejectsSaveAndImportWithoutLosingOldPath() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var failing = false
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory, beforePathDelete: { _ in
            if failing { throw CocoaError(.fileWriteNoPermission) }
        })
        let original = try store.save(sampleRoute(name: "原路线"))
        let catalog = defaults.data(forKey: "saved_routes_v1")
        var noPath = original
        noPath.pathPoints = nil
        failing = true
        XCTAssertThrowsError(try store.save(noPath))
        XCTAssertEqual(store.importTransferred([noPath]).failed, 1)
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), catalog)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, [original])
        failing = false
        try store.save(noPath)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory).routes, [noPath])
    }

    func testCleanupFailureLeavesOnlyUnreferencedFileAfterSuccessfulCapacitySave() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory, beforePathDelete: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let oldest = try store.save(sampleRoute(name: "最旧"))
        for index in 0..<SavedRouteStore.limit {
            try store.save(sampleRoute(name: "新路线 \(index)"))
        }
        let restored = SavedRouteStore(defaults: defaults, pathDirectory: isolatedDirectory)
        XCTAssertEqual(restored.routes, store.routes)
        XCTAssertEqual(restored.routes.count, SavedRouteStore.limit)
        XCTAssertFalse(restored.routes.contains { $0.id == oldest.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedDirectory.appendingPathComponent("\(oldest.id).json").path))
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
