import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class LocationActionCoordinatorTests: XCTestCase {
    func testApplyStartsProxyAndWritesTheFavoriteWGS84Pair() async {
        let proxy = FakeLocationActionProxy()
        let settings = FakeLocationActionSettingsStore()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .gcj02
        )

        let applied = await coordinator.apply(favorite)
        XCTAssertTrue(applied)
        XCTAssertTrue(proxy.isRunning)
        XCTAssertEqual(proxy.lastCoordinates?.latitude, favorite.coordinatePair.wgs84.latitude)
        XCTAssertEqual(proxy.lastCoordinates?.longitude, favorite.coordinatePair.wgs84.longitude)
        XCTAssertEqual(settings.saved?.latitude, favorite.coordinatePair.wgs84.latitude)
        XCTAssertEqual(settings.saved?.longitude, favorite.coordinatePair.wgs84.longitude)
        XCTAssertEqual(proxy.lastCoordinates?.accuracy, 20)
        XCTAssertEqual(settings.saved?.accuracy, 20)
        XCTAssertTrue(settings.saved?.enabled == true)
    }

    func testClearWritesDisabledCoordinatesAndClearsSettings() {
        let proxy = FakeLocationActionProxy(isRunning: true)
        let settings = FakeLocationActionSettingsStore()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)

        coordinator.clear()

        XCTAssertEqual(proxy.lastCoordinates?.latitude, 0)
        XCTAssertEqual(proxy.lastCoordinates?.longitude, 0)
        XCTAssertFalse(proxy.lastCoordinates?.enabled ?? true)
        XCTAssertFalse(settings.saved?.enabled ?? true)
        XCTAssertFalse(coordinator.virtualLocationEnabled)
    }

    func testApplyVerifiedRejectsInactiveProxyWithoutWritingCoordinates() {
        let proxy = FakeLocationActionProxy()
        let settings = FakeLocationActionSettingsStore()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
        let favorite = FavoriteLocation(name: "深圳湾", latitude: 22.494, longitude: 113.951, accuracy: 20)

        XCTAssertFalse(coordinator.applyVerified(favorite))
        XCTAssertNil(proxy.lastCoordinates)
        XCTAssertNil(settings.saved)
    }

    func testApplyOffsetsWGS84WhenRadiusIsEnabled() async {
        let proxy = FakeLocationActionProxy()
        let settings = FakeLocationActionSettingsStore()
        let coordinator = LocationActionCoordinator(
            proxy: proxy,
            settings: settings,
            randomRadiusMeters: { 50 },
            offsetWGS84: { latitude, longitude, radius in
                XCTAssertEqual(radius, 50)
                return (latitude + 0.01, longitude - 0.02)
            }
        )
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .gcj02
        )

        let applied = await coordinator.apply(favorite)

        XCTAssertTrue(applied)
        XCTAssertEqual(proxy.lastCoordinates?.latitude, favorite.coordinatePair.wgs84.latitude + 0.01)
        XCTAssertEqual(proxy.lastCoordinates?.longitude, favorite.coordinatePair.wgs84.longitude - 0.02)
        XCTAssertEqual(settings.saved?.latitude, favorite.coordinatePair.wgs84.latitude + 0.01)
        XCTAssertEqual(settings.saved?.longitude, favorite.coordinatePair.wgs84.longitude - 0.02)
    }

    func testUpdateSpoofedWGS84WritesExactCoordinatesWithoutRadius() {
        let proxy = FakeLocationActionProxy(isRunning: true)
        let settings = FakeLocationActionSettingsStore()
        let coordinator = LocationActionCoordinator(
            proxy: proxy,
            settings: settings,
            randomRadiusMeters: { 50 },
            offsetWGS84: { _, _, _ in
                XCTFail("route writes must not apply a random offset")
                return (0, 0)
            }
        )

        XCTAssertTrue(coordinator.updateSpoofedWGS84(latitude: 22.5, longitude: 113.9, accuracy: 15))
        XCTAssertEqual(proxy.lastCoordinates?.latitude, 22.5)
        XCTAssertEqual(proxy.lastCoordinates?.longitude, 113.9)
        XCTAssertEqual(proxy.lastCoordinates?.accuracy, 15)
        XCTAssertEqual(settings.saved?.latitude, 22.5)
        XCTAssertEqual(settings.saved?.longitude, 113.9)
        XCTAssertEqual(settings.saved?.accuracy, 15)
        XCTAssertEqual(settings.saved?.enabled, true)
        XCTAssertTrue(coordinator.virtualLocationEnabled)
    }

    func testUpdateSpoofedWGS84RejectsStoppedProxyWithoutWriting() {
        let proxy = FakeLocationActionProxy()
        let settings = FakeLocationActionSettingsStore()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)

        XCTAssertFalse(coordinator.updateSpoofedWGS84(latitude: 22.5, longitude: 113.9, accuracy: 15))
        XCTAssertNil(proxy.lastCoordinates)
        XCTAssertNil(settings.saved)
        XCTAssertFalse(coordinator.virtualLocationEnabled)
    }
}

@MainActor
private final class FakeLocationActionProxy: LocationActionProxying {
    struct Coordinates: Equatable {
        let latitude: Double
        let longitude: Double
        let enabled: Bool
        let accuracy: Int
    }

    var isRunning: Bool
    private(set) var lastCoordinates: Coordinates?

    init(isRunning: Bool = false) {
        self.isRunning = isRunning
    }

    func start() async throws {
        isRunning = true
    }

    func setCoords(lat: Double, lon: Double, enabled: Bool, accuracy: Int) -> UInt64 {
        lastCoordinates = Coordinates(latitude: lat, longitude: lon, enabled: enabled, accuracy: accuracy)
        return 1
    }
}

@MainActor
private final class FakeLocationActionSettingsStore: LocationActionSettingsStoring {
    private(set) var saved: WlocSettings?

    func load() -> WlocSettings? { saved }
    func save(_ settings: WlocSettings) { saved = settings }
    func clear() { saved = WlocSettings(longitude: 0, latitude: 0, accuracy: 25, enabled: false) }
}
