import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class RouteImportPreparationTests: RouteImportTestCase {
    func testAllFormatsFromClipboardAndFileRoundTripThroughStoreAndExport() async throws {
        for format in ["gpx", "kml", "json"] {
            let text = format == "json" ? try RouteImportSamples.json([RouteImportSamples.route(count: 1000)])
                : RouteImportSamples.xml(format)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("合成-\(UUID()).\(format)")
            try Data(text.utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            for input in [RouteImportPreparation.Input.clipboard(text), .file(url)] {
                let (store, defaults, directory) = isolatedStore()
                let coordinator = RouteImportCoordinator(), page = UUID()
                coordinator.enterPage(page)
                coordinator.start(input, pageID: page, isPageActive: { true }) { store.importTransferred($0.routes) }
                await coordinator.waitForCompletion()
                let saved = try XCTUnwrap(store.routes.first)
                XCTAssertLessThanOrEqual(saved.pathPoints!.count, 400)
                XCTAssertEqual(coordinator.notice?.title, "路线已导入")
                let reopened = SavedRouteStore(defaults: defaults, pathDirectory: directory)
                XCTAssertEqual(reopened.routes, store.routes)
                let exported = try XCTUnwrap(RouteTransfer.decode(reopened.exportTransferred()).first)
                XCTAssertEqual(exported.pathPoints, saved.pathPoints)
                XCTAssertEqual(exported.id, saved.id)
                XCTAssertEqual(exported.createdAt.timeIntervalSince1970, saved.createdAt.timeIntervalSince1970, accuracy: 0.001)
                var normalizedDate = exported
                normalizedDate.createdAt = saved.createdAt
                XCTAssertEqual(normalizedDate, saved)
            }
        }
    }

    func testEmptyMalformedCoordinatesAndLegacyErrorMessages() async throws {
        var invalid = RouteImportSamples.route()
        invalid.start = CoordinateConverter.coordinatePair(lat: 91, lon: 0, mapCoordinateSystem: .wgs84)
        let cases = [
            (" \n", "剪贴板里没有路线备份"),
            ("broken", "路线备份不是有效的 JSON"),
            ("<gpx><trk>", "GPX 文件不是有效的 XML"),
            ("<kml><Placemark>", "KML 文件不是有效的 XML"),
            ("<gpx/>", "GPX 里没有足够长的轨迹"),
            ("<kml/>", "KML 里没有足够长的轨迹"),
            ("PKzip", "暂不支持 KMZ 压缩包，请解压后导入 KML"),
            (try RouteImportSamples.json([invalid]), "路线备份不是有效的 JSON"),
            ("<gpx><trk><trkpt lat=\"91\" lon=\"2\"/><trkpt lat=\"1\" lon=\"2\"/></trk></gpx>", "GPX 里没有足够长的轨迹"),
            ("<kml><Placemark><LineString><coordinates>2,91 2,1</coordinates></LineString></Placemark></kml>", "KML 里没有足够长的轨迹")
        ]
        for (text, message) in cases {
            let coordinator = RouteImportCoordinator(), page = UUID()
            let (store, _, _) = isolatedStore()
            coordinator.enterPage(page)
            await run(text, coordinator: coordinator, page: page, store: store)
            XCTAssertTrue(store.routes.isEmpty)
            XCTAssertEqual(coordinator.notice?.title, "路线导入失败")
            XCTAssertEqual(coordinator.notice?.message, message)
        }
    }

    func testFormatFallbackBeyondPrefixAndFileNameRemainCompatible() throws {
        for format in ["gpx", "kml"] {
            let text = String(repeating: " ", count: 2) + "<!--" + String(repeating: "a", count: 600) + "-->"
                + RouteImportSamples.xml(format).replacingOccurrences(of: "<name>合成路线</name>", with: "")
            let input = RouteImportPreparation.Input.file(URL(fileURLWithPath: "/合成备用名称.json"))
            let prepared = try RouteImportPreparation.prepare(input, access: .init(begin: { _ in false }, read: { _ in Data(text.utf8) }))
            XCTAssertEqual(prepared.routes.first?.name, "合成备用名称")
            XCTAssertThrowsError(try RouteImportPreparation.prepare(input, access: .init(read: { _ in Data(text.utf8) })) { stage in
                if stage == .parsing { throw CancellationError() }
            }) { XCTAssertTrue($0 is CancellationError) }
        }
    }

    func testAccessBalancedOnSuccessReadFailureAndCancellation() throws {
        for granted in [true, false] {
            for mode in ["success", "failure", "cancel"] {
                var begins = 0, ends = 0, reads = 0
                let access = RouteImportPreparation.FileAccess(begin: { _ in begins += 1; return granted },
                    end: { _ in ends += 1 }, read: { _ in
                        reads += 1
                        if mode == "failure" { throw CocoaError(.fileReadUnknown) }
                        return Data(RouteImportSamples.xml("gpx", count: 5).utf8)
                    })
                do {
                    _ = try RouteImportPreparation.prepare(.file(URL(fileURLWithPath: "/synthetic")), access: access) { stage in
                        if stage == .afterRead {
                            XCTAssertEqual(ends, granted ? 1 : 0)
                            if mode == "cancel" { throw CancellationError() }
                        }
                    }
                    XCTAssertEqual(mode, "success")
                } catch { XCTAssertNotEqual(mode, "success") }
                XCTAssertEqual(begins, 1); XCTAssertEqual(reads, 1); XCTAssertEqual(ends, granted ? 1 : 0)
            }
        }
        var reads = 0
        XCTAssertThrowsError(try RouteImportPreparation.prepare(.file(URL(fileURLWithPath: "/synthetic")),
            access: .init(begin: { _ in reads += 1; return true })) { _ in throw CancellationError() })
        XCTAssertEqual(reads, 0)
    }

    func testCapacityDuplicateIDGeometryAndLateInvalidRecord() async throws {
        let original = RouteImportSamples.route(0)
        var sameID = original; sameID.name = "相同 ID"
        var geometry = RouteImportSamples.route(0, name: "几何匹配最后项")
        geometry.createdAt = Date(timeIntervalSince1970: 300)
        let incoming = [original] + (1..<55).map { RouteImportSamples.route($0) } + [sameID, geometry]
        let (store, defaults, directory) = isolatedStore()
        let coordinator = RouteImportCoordinator(), page = UUID()
        coordinator.enterPage(page)
        await run(try RouteImportSamples.json(incoming), coordinator: coordinator, page: page, store: store)
        XCTAssertEqual(coordinator.notice?.message, "新增 50 条，更新 2 条，超出上限 5 条，失败 0 条")
        XCTAssertEqual(store.routes.last?.id, original.id)
        XCTAssertEqual(store.routes.last?.createdAt, original.createdAt)
        XCTAssertEqual(store.routes.last?.name, geometry.name)
        XCTAssertEqual(store.routes.map(\.id), Array(incoming.prefix(50).reversed()).map(\.id))
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: directory).routes, store.routes)
        var bad = RouteImportSamples.route(70)
        bad.end = CoordinateConverter.coordinatePair(lat: 95, lon: 0, mapCoordinateSystem: .wgs84)
        let before = store.routes
        await run(try RouteImportSamples.json(incoming + [bad]), coordinator: coordinator, page: page, store: store)
        XCTAssertEqual(store.routes, before)
        XCTAssertEqual(coordinator.notice?.title, "路线导入失败")
    }

    func testPreparedPathWriteFailurePreservesOldPathCatalogAndMemory() async throws {
        var shouldFail = false
        let original = RouteImportSamples.route(1, count: 1000)
        let (store, defaults, directory) = isolatedStore { id in
            if shouldFail && id == original.id { throw CocoaError(.fileWriteOutOfSpace) }
        }
        let saved = try store.save(original)
        let catalog = defaults.data(forKey: "saved_routes_v1")
        let pathURL = directory.appendingPathComponent("\(saved.id).json")
        let bytes = try Data(contentsOf: pathURL)
        shouldFail = true
        var replacement = original
        replacement.name = "不应保存"
        replacement.pathPoints = RouteImportSamples.route(2, count: 2000).pathPoints
        let coordinator = RouteImportCoordinator(), page = UUID()
        coordinator.enterPage(page)
        await run(try RouteImportSamples.json([replacement]), coordinator: coordinator, page: page, store: store)
        XCTAssertEqual(store.routes, [saved])
        XCTAssertEqual(defaults.data(forKey: "saved_routes_v1"), catalog)
        XCTAssertEqual(try Data(contentsOf: pathURL), bytes)
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: directory).routes, [saved])
        XCTAssertEqual(coordinator.notice?.message, "新增 0 条，更新 0 条，超出上限 0 条，失败 1 条")
    }

    func testEachLargePathSimplifiedOnlyDuringPreparation() throws {
        for format in ["gpx", "kml", "json"] {
            var sizes: [Int] = []
            let text = format == "json" ? try RouteImportSamples.json([RouteImportSamples.route(count: 1000)])
                : RouteImportSamples.xml(format)
            let prepared = try RouteImportPreparation.prepare(.clipboard(text)) { stage in
                if case .simplifying(let count) = stage, count > 400 { sizes.append(count) }
            }
            XCTAssertEqual(sizes, [1000])
            XCTAssertLessThanOrEqual(prepared.routes[0].pathPoints!.count, 400)
            let (store, _, _) = isolatedStore()
            XCTAssertEqual(store.importTransferred(prepared.routes).added, 1)
            // 保存接收的已是 <=400 点，原简化器的第一道判断直接返回，不再遍历大输入。
            XCTAssertEqual(store.routes[0].pathPoints, prepared.routes[0].pathPoints)
        }
    }

    func testLargeGPXCompletesOnBackgroundStack() async throws {
        let text = RouteImportSamples.xml("gpx", count: 100000)
        let coordinator = RouteImportCoordinator(), page = UUID()
        let (store, _, _) = isolatedStore()
        coordinator.enterPage(page)
        await run(text, coordinator: coordinator, page: page, store: store)
        let path = try XCTUnwrap(store.routes.first?.pathPoints)
        XCTAssertGreaterThanOrEqual(path.count, 2)
        XCTAssertLessThanOrEqual(path.count, 400)
        XCTAssertEqual(path.first?.wgs84.latitude, 20)
        XCTAssertEqual(path.last?.wgs84.latitude ?? 0, 20.99999, accuracy: 0.0000001)
    }

    func testCollinearReturnAndDateLineSurvivePreparedImport() async throws {
        for origin in [0.0, 179.99] {
            let points = (0...500).map { i in
                let offset = i <= 250 ? Double(i) / 250 * 0.02 : 0.02 - Double(i - 250) / 250 * 0.015
                return CoordinateConverter.coordinatePair(lat: 0,
                    lon: CoordinateConverter.normalizedLongitude(origin + offset), mapCoordinateSystem: .wgs84)
            }
            var route = RouteImportSamples.route()
            route.start = points[0]; route.end = points[500]; route.pathPoints = points
            let (store, _, _) = isolatedStore()
            let coordinator = RouteImportCoordinator(), page = UUID()
            coordinator.enterPage(page)
            await run(try RouteImportSamples.json([route]), coordinator: coordinator, page: page, store: store)
            XCTAssertEqual(store.routes.first?.pathPoints, [points[0], points[250], points[500]])
        }
    }
}
