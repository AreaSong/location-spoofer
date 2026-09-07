import XCTest
import CoreLocation
@testable import PaopaoLocationSpoofer

final class RecentSelectionStoreTests: XCTestCase {
    func testRecordingMoreThanLimitKeepsTenMostRecent() {
        let suite = "RecentSelectionStoreTests.limit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSelectionStore(defaults: defaults)

        for index in 0..<11 {
            store.record(
                name: "地点\(index)",
                coordinatePair: pair(latitude: 22.5 + Double(index) * 0.01, longitude: 113.9)
            )
        }

        XCTAssertEqual(store.items.count, 10)
        XCTAssertEqual(store.items.first?.name, "地点10")
        XCTAssertEqual(store.items.last?.name, "地点1")
        XCTAssertFalse(store.items.contains { $0.name == "地点0" })
        XCTAssertEqual(RecentSelectionStore(defaults: defaults).items.map(\.name), store.items.map(\.name))
    }

    func testDuplicateWGS84KeepsSingleEntryAndMovesItToFront() {
        let suite = "RecentSelectionStoreTests.dedupe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSelectionStore(defaults: defaults)
        let first = pair(latitude: 22.544577, longitude: 113.94114)
        let duplicate = pair(latitude: 22.5445774, longitude: 113.9411404)
        let other = pair(latitude: 31.2304, longitude: 121.4737)

        store.record(name: "深圳湾", coordinatePair: first)
        store.record(name: "上海", coordinatePair: other)
        store.record(name: "深圳湾公园", coordinatePair: duplicate)

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.name, "深圳湾公园")
        XCTAssertEqual(store.items.last?.name, "上海")
    }

    func testUpdateNameRewritesMatchingRecentEntry() {
        let suite = "RecentSelectionStoreTests.rename.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentSelectionStore(defaults: defaults)
        let target = pair(latitude: 22.544577, longitude: 113.94114)
        store.record(name: "22.5446, 113.9411", coordinatePair: target)
        store.updateNameIfPresent(for: target, name: "深圳湾公园")

        XCTAssertEqual(store.items.first?.name, "深圳湾公园")
    }

    private func pair(latitude: Double, longitude: Double) -> CoordinatePair {
        CoordinateConverter.coordinatePair(
            lat: latitude,
            lon: longitude,
            mapCoordinateSystem: .wgs84
        )
    }
}
