import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class SimulationSettingsStoreTests: XCTestCase {
    func testRandomRadiusDefaultsAndClamps() {
        let suite = "RandomRadiusStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = RandomRadiusStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.radius, RandomRadiusStore.defaultMeters)
        XCTAssertEqual(store.effectiveRadiusMeters, 0)

        store.setEnabled(true)
        XCTAssertEqual(store.effectiveRadiusMeters, RandomRadiusStore.defaultMeters)

        store.setRadius(5)
        XCTAssertEqual(store.radius, RandomRadiusStore.minimumMeters)
        store.setRadius(500)
        XCTAssertEqual(store.radius, RandomRadiusStore.maximumMeters)
        XCTAssertEqual(RandomRadiusStore(defaults: defaults).radius, RandomRadiusStore.maximumMeters)
    }

    func testLocationAccuracyDefaultsAndClamps() {
        let suite = "LocationAccuracyStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = LocationAccuracyStore(defaults: defaults)
        XCTAssertEqual(store.meters, LocationAccuracyStore.defaultMeters)

        store.setMeters(1)
        XCTAssertEqual(store.meters, LocationAccuracyStore.minimumMeters)
        store.setMeters(250)
        XCTAssertEqual(store.meters, LocationAccuracyStore.maximumMeters)
        XCTAssertEqual(LocationAccuracyStore(defaults: defaults).meters, LocationAccuracyStore.maximumMeters)
    }
}
