import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class MapDisplayStyleTests: XCTestCase {
    func testCycleOrderAndPersistence() {
        XCTAssertEqual(MapDisplayStyle.standard.next, .satellite)
        XCTAssertEqual(MapDisplayStyle.satellite.next, .hybrid)
        XCTAssertEqual(MapDisplayStyle.hybrid.next, .standard)
        XCTAssertEqual(MapDisplayStyle.standard.title, "标准")
        XCTAssertEqual(MapDisplayStyle.satellite.title, "卫星")
        XCTAssertEqual(MapDisplayStyle.hybrid.title, "混合")

        let suite = "MapStyleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MapStyleStore(defaults: defaults)
        XCTAssertEqual(store.style, .standard)
        store.cycle()
        XCTAssertEqual(store.style, .satellite)
        XCTAssertEqual(MapStyleStore(defaults: defaults).style, .satellite)
        store.setStyle(.hybrid)
        XCTAssertEqual(MapStyleStore(defaults: defaults).style, .hybrid)
    }
}
