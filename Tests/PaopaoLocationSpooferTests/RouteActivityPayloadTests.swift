import XCTest
import ActivityKit
@testable import PaopaoLocationSpoofer

@available(iOS 16.2, *)
final class RouteActivityPayloadTests: XCTestCase {
    func testLongChineseNameFitsFullPayload() throws {
        let name = String(repeating: "汉", count: 2000)
        let snapshot = try XCTUnwrap(SpotActivitySync.snapshot(
            isVerifying: false, isActive: true, needsSwitch: false, failed: false,
            placeName: name, coordinateStandard: "WGS-84", accuracyMeters: 10
        ))
        let payload = try RouteActivityPayload.prepare(name: name, state: RouteActivityPayload.spotState(snapshot))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(payload).count, 3800)
    }

    func testNormalRouteSpotAndWalkKeepAllFields() throws {
        for state in try sampleStates(name: "深圳湾") {
            let payload = try RouteActivityPayload.prepare(name: "深圳湾", state: state)
            XCTAssertEqual(payload.attributes.name, "深圳湾")
            XCTAssertEqual(payload.state, state)
            try assertFitsAndRoundTrips(payload)
        }
    }

    func testLongUnicodeASCIIAndEscapedNamesOnCreateAndUpdate() throws {
        let samples = [String(repeating: "汉", count: 2000), String(repeating: "abc", count: 4000),
                       String(repeating: "👩🏽‍💻🇨🇳", count: 1000), String(repeating: "e\u{301}", count: 4000),
                       String(repeating: "\"\\/\n\t\u{0001}", count: 2000)]
        for name in samples {
            for state in try sampleStates(name: name) {
                let created = try RouteActivityPayload.prepare(name: name, state: state)
                try assertFitsAndRoundTrips(created)
                assertWholeCharacterPrefix(created.attributes.name, of: name)
                assertWholeCharacterPrefix(created.state.title, of: name)
                var updated = state
                updated.title = name + "后续更新"
                updated.errorText = "设备连接失败，打开 App 检查。" + name
                let update = try RouteActivityPayload.prepare(name: updated.title, state: updated,
                                                             existingAttributes: created.attributes)
                XCTAssertEqual(update.attributes.name, created.attributes.name)
                XCTAssertTrue(update.state.errorText.hasPrefix("设备连接失败"))
                try assertFitsAndRoundTrips(update)
                assertProtectedFields(update.state, equalTo: updated)
            }
        }
    }

    func testSeveralLongFieldsPreserveCommandsAndKeyState() throws {
        let long = String(repeating: "复杂👩🏽‍💻\"\\\n", count: 2000)
        let id = UUID()
        var state = try XCTUnwrap(sampleStates(name: long).first)
        let fields: [WritableKeyPath<RouteActivityAttributes.ContentState, String>] = [
            \.title, \.detailText, \.distanceText, \.timeText, \.speedText,
            \.primaryTitle, \.secondaryTitle, \.tertiaryTitle
        ]
        for field in fields { state[keyPath: field] = long }
        state.kind = "spot"
        state.phase = "actionFailed"
        state.statusText = "操作失败"
        state.errorText = "设备已断开，请打开 App 检查连接。" + long
        state.primaryAction = "switchFavorite:\(id.uuidString)"
        state.secondaryAction = "retry"
        state.tertiaryAction = "openApp"
        state.retryCommand = state.primaryAction
        let payload = try RouteActivityPayload.prepare(name: long, state: state)
        try assertFitsAndRoundTrips(payload)
        assertProtectedFields(payload.state, equalTo: state)
        XCTAssertEqual(payload.state.statusText, state.statusText)
        XCTAssertTrue(payload.state.errorText.hasPrefix("设备已断开"))
        XCTAssertEqual(payload.state.isWarning, state.isWarning)
    }

    func testExactlyAtBudgetAndOneByteBelow() throws {
        let state = try XCTUnwrap(sampleStates(name: "边界").first)
        let payload = try RouteActivityPayload.prepare(name: "边界", state: state)
        let size = try JSONEncoder().encode(payload).count
        XCTAssertEqual(try RouteActivityPayload.prepare(name: "边界", state: state, limit: size).state, state)
        XCTAssertThrowsError(try RouteActivityPayload.prepare(name: "边界", state: state, limit: size - 1))
    }

    func testProtectedCommandAndAdoptedAttributesCannotBeShortened() throws {
        var state = try XCTUnwrap(sampleStates(name: "正常").first)
        state.retryCommand = String(repeating: "x", count: 4000)
        XCTAssertThrowsError(try RouteActivityPayload.prepare(name: "正常", state: state)) {
            XCTAssertEqual($0 as? RouteActivityPayload.BudgetError, .protectedFieldsTooLarge)
        }
        state.retryCommand = "resume"
        let legacy = RouteActivityAttributes(name: String(repeating: "汉", count: 2000))
        XCTAssertThrowsError(try RouteActivityPayload.prepare(name: "新标题", state: state, existingAttributes: legacy))
        XCTAssertEqual(legacy.name.count, 2000)
        // 失败不污染输入，纠正后同一状态仍能生成有效载荷。
        try assertFitsAndRoundTrips(RouteActivityPayload.prepare(name: "新标题", state: state))
    }

    func testNonfiniteProgressFailsWithoutEncodingOrPublishing() throws {
        var state = try XCTUnwrap(sampleStates(name: "路线").first)
        state.progress = .nan
        XCTAssertThrowsError(try RouteActivityPayload.prepare(name: "路线", state: state)) {
            XCTAssertEqual($0 as? RouteActivityPayload.BudgetError, .encodingFailed)
        }
    }

    func testAdoptionRecountsCanonicallyEquivalentNamesWithDifferentBytes() throws {
        let name = String(repeating: "각", count: 80)
        let legacy = RouteActivityAttributes(name: name.decomposedStringWithCanonicalMapping)
        XCTAssertEqual(name, legacy.name)
        XCTAssertFalse(name.utf8.elementsEqual(legacy.name.utf8))
        var state = try XCTUnwrap(sampleStates(name: name).first)
        state.detailText = ""
        let emptySize = try RouteActivityPayload(attributes: .init(name: name), state: state).encodedSize()
        state.detailText = String(repeating: "x", count: RouteActivityPayload.byteLimit - emptySize)
        let created = try RouteActivityPayload.prepare(name: name, state: state)
        XCTAssertEqual(try created.encodedSize(), RouteActivityPayload.byteLimit)
        XCTAssertGreaterThan(try RouteActivityPayload(attributes: legacy, state: created.state).encodedSize(), 4096)
        let adopted = try created.reconciled(with: legacy, sourceState: state)
        XCTAssertTrue(adopted.attributes.name.utf8.elementsEqual(legacy.name.utf8))
        try assertFitsAndRoundTrips(adopted)
        assertProtectedFields(adopted.state, equalTo: state)
    }

    func testSingleOversizedGraphemeIsNotSplit() throws {
        let name = "a" + String(repeating: "\u{301}", count: 5000)
        XCTAssertEqual(name.count, 1)
        let state = try XCTUnwrap(sampleStates(name: name).first)
        let payload = try RouteActivityPayload.prepare(name: name, state: state)
        XCTAssertEqual(payload.attributes.name, "…")
        XCTAssertEqual(payload.state.title, "…")
        try assertFitsAndRoundTrips(payload)
    }

    func testLongNamesRemainInStoresAndExports() throws {
        let name = String(repeating: "原始名称👩🏽‍💻", count: 500)
        let suite = "RouteActivityPayloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let favorites = FavoriteLocationStore(defaults: defaults)
        let favorite = favorites.save(name: name, mapCoordinate: .init(latitude: 22, longitude: 113),
                                      mapCoordinateSystem: .wgs84, accuracy: 10)
        let routes = SavedRouteStore(defaults: defaults, pathDirectory: directory)
        let route = try routes.save(SavedRoute(name: name, start: favorite.coordinatePair,
                                               end: favorite.coordinatePair, travelMode: .walk,
                                               speedKilometersPerHour: 5, offsetMeters: 0, repeatMode: .once, pathPoints: nil))
        let favoriteExport = try FavoriteTransfer.encode([favorite])
        let routeExport = try RouteTransfer.encode([route])
        for state in try sampleStates(name: name) { _ = try RouteActivityPayload.prepare(name: name, state: state) }
        XCTAssertEqual(FavoriteLocationStore(defaults: defaults).favorites.first?.name, name)
        let restored = SavedRouteStore(defaults: defaults, pathDirectory: directory).routes.first
        XCTAssertEqual(restored?.name, name)
        XCTAssertEqual(restored?.id, route.id)
        XCTAssertEqual(try FavoriteTransfer.encode([favorite]), favoriteExport)
        XCTAssertEqual(try RouteTransfer.encode([route]), routeExport)
        XCTAssertEqual(try FavoriteTransfer.decode(favoriteExport).first?.name, name)
        XCTAssertEqual(try RouteTransfer.decode(routeExport).first?.name, name)
    }

    private func sampleStates(name: String) throws -> [RouteActivityAttributes.ContentState] {
        let route = try XCTUnwrap(RouteActivitySync.snapshot(phase: .playing, statusMessage: "", routeName: name,
                                                            remainingMeters: 800, speedMetersPerSecond: 1.4,
                                                            progress: 0.2, symbolName: "figure.walk"))
        let spot = try XCTUnwrap(SpotActivitySync.snapshot(isVerifying: false, isActive: true, needsSwitch: false,
                                                         failed: false, placeName: name,
                                                         coordinateStandard: "WGS-84", accuracyMeters: 10))
        let walk = try XCTUnwrap(SpotActivitySync.snapshot(isVerifying: false, isActive: true, needsSwitch: false,
                                                         failed: false, placeName: name,
                                                         coordinateStandard: "WGS-84", accuracyMeters: 10,
                                                         isPhysicalWalk: true, walkMovedMeters: 80,
                                                         walkHeadingDegrees: 45))
        return [RouteActivityPayload.routeState(RouteActivitySync.normalized(route)),
                RouteActivityPayload.spotState(SpotActivitySync.normalized(spot)),
                RouteActivityPayload.spotState(SpotActivitySync.normalized(walk))]
    }

    private func assertFitsAndRoundTrips(_ payload: RouteActivityPayload, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        // 分别编码实际 ActivityKit 类型，并额外核对包含包装键的完整计量对象。
        let attributes = try encoder.encode(payload.attributes)
        let state = try encoder.encode(payload.state)
        XCTAssertLessThanOrEqual(attributes.count + state.count, 3800, file: file, line: line)
        XCTAssertLessThanOrEqual(try encoder.encode(payload).count, 3800, file: file, line: line)
        XCTAssertEqual(try JSONDecoder().decode(RouteActivityAttributes.ContentState.self, from: state), payload.state,
                       file: file, line: line)
    }

    private func assertWholeCharacterPrefix(_ value: String, of source: String, file: StaticString = #filePath, line: UInt = #line) {
        if value == source { return }
        XCTAssertTrue(value.hasSuffix("…"), file: file, line: line)
        let prefix = value.dropLast()
        XCTAssertEqual(String(source.prefix(prefix.count)), String(prefix), file: file, line: line)
        XCTAssertFalse(value.contains("\u{FFFD}"), file: file, line: line)
    }

    private func assertProtectedFields(_ actual: RouteActivityAttributes.ContentState,
                                       equalTo expected: RouteActivityAttributes.ContentState,
                                       file: StaticString = #filePath, line: UInt = #line) {
        for field in [\RouteActivityAttributes.ContentState.primaryAction, \.secondaryAction, \.tertiaryAction,
                      \.retryCommand, \.kind, \.phase, \.symbolName, \.modeSymbolName] {
            XCTAssertEqual(actual[keyPath: field], expected[keyPath: field], file: file, line: line)
        }
        XCTAssertEqual(actual.progress, expected.progress, file: file, line: line)
        XCTAssertEqual(actual.showsProgress, expected.showsProgress, file: file, line: line)
    }
}
