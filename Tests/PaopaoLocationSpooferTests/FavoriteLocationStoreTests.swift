import XCTest
import CoreLocation
@testable import PaopaoLocationSpoofer

final class FavoriteLocationStoreTests: XCTestCase {
    func testSavingFavoriteSelectsItAndPersistsAcrossStoreInstances() {
        let suite = "FavoriteLocationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoriteLocationStore(defaults: defaults)
        let favorite = store.save(
            name: "深圳湾",
            mapCoordinate: .init(latitude: 22.494, longitude: 113.951),
            mapCoordinateSystem: .gcj02,
            accuracy: 20
        )

        XCTAssertEqual(store.selectedFavoriteID, favorite.id)
        XCTAssertEqual(FavoriteLocationStore(defaults: defaults).selectedFavorite?.name, "深圳湾")
    }

    func testSelectingMatchingCoordinatePairRestoresFavoriteSelection() {
        let suite = "FavoriteLocationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoriteLocationStore(defaults: defaults)
        let favorite = store.save(
            name: "深圳湾",
            coordinatePair: CoordinateConverter.coordinatePair(
                lat: 22.491_438,
                lon: 113.945_702,
                mapCoordinateSystem: .wgs84
            ),
            accuracy: 20
        )
        store.select(nil)

        let nearbyRealtimePair = CoordinateConverter.coordinatePair(
            lat: 22.491_488,
            lon: 113.945_752,
            mapCoordinateSystem: .wgs84
        )
        XCTAssertEqual(store.selectMatching(coordinatePair: nearbyRealtimePair)?.id, favorite.id)
        XCTAssertEqual(store.selectedFavoriteID, favorite.id)

        let unrelatedPair = CoordinateConverter.coordinatePair(
            lat: 31.2304,
            lon: 121.4737,
            mapCoordinateSystem: .wgs84
        )
        XCTAssertNil(store.selectMatching(coordinatePair: unrelatedPair))
        XCTAssertNil(store.selectedFavoriteID)
    }

    func testFavoriteStoresBothFormsAndSelectsMatchingPairWithoutReadConversion() {
        let suite = "FavoriteLocationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let wgs = CLLocationCoordinate2D(latitude: 22.491_438, longitude: 113.945_702)
        let favorite = FavoriteLocation(
            name: "深圳湾",
            coordinatePair: .init(mapCoordinate: wgs, mapCoordinateSystem: .wgs84),
            accuracy: 20
        )

        XCTAssertEqual(favorite.coordinatePair.coordinate(for: .wgs84).latitude, wgs.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(favorite.coordinatePair.coordinate(for: .wgs84).longitude, wgs.longitude, accuracy: 0.000_000_1)
        XCTAssertNotEqual(favorite.coordinatePair.gcj02.latitude, wgs.latitude)
        XCTAssertNotEqual(favorite.coordinatePair.gcj02.longitude, wgs.longitude)
    }

    func testSavingPrecomputedPairDoesNotReinterpretItAfterMapTypeRefresh() {
        let suite = "FavoriteLocationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.296_642,
            lon: 114.172_175,
            mapCoordinateSystem: .wgs84
        )

        let favorite = FavoriteLocationStore(defaults: defaults).save(
            name: "香港天文台",
            coordinatePair: pair,
            accuracy: 25
        )

        XCTAssertEqual(favorite.coordinatePair, pair)
    }

    func testLegacyFavoriteIsUpgradedAsDomesticGCJAndRewritten() throws {
        let suite = "FavoriteLocationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = LegacyFavoritePayload(
            id: id,
            name: "旧收藏",
            latitude: 22.544_577,
            longitude: 113.941_14,
            accuracy: 25,
            createdAt: createdAt
        )
        defaults.set(try JSONEncoder().encode([payload]), forKey: "favorite_locations")

        let store = FavoriteLocationStore(defaults: defaults)
        XCTAssertTrue(store.favorites[0].isLegacyCoordinateRecord)
        XCTAssertEqual(store.favorites[0].coordinatePair.gcj02.latitude, payload.latitude, accuracy: 0.000_000_1)
        XCTAssertNotEqual(store.favorites[0].coordinatePair.wgs84.longitude, payload.longitude)

        try store.migrateLegacyCoordinates()
        let reloaded = FavoriteLocationStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites[0].id, id)
        XCTAssertEqual(reloaded.favorites[0].name, "旧收藏")
        XCTAssertFalse(reloaded.favorites[0].isLegacyCoordinateRecord)
    }

    func testOverseasPairUsesIdentityConversion() {
        let eiffelTower = CoordinateConverter.coordinatePair(lat: 48.858_37, lon: 2.294_481, mapCoordinateSystem: .wgs84)

        XCTAssertEqual(eiffelTower.wgs84.latitude, eiffelTower.gcj02.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(eiffelTower.wgs84.longitude, eiffelTower.gcj02.longitude, accuracy: 0.000_000_1)
    }

    func testDomesticMapCoordinateMatchesPreviouslyActivatedWGS84Value() {
        let gcj = CLLocationCoordinate2D(latitude: 22.544_577, longitude: 113.941_14)
        let pair = CoordinatePair(mapCoordinate: gcj, mapCoordinateSystem: .gcj02)

        XCTAssertTrue(pair.matchesWGS84(
            latitude: pair.wgs84.latitude,
            longitude: pair.wgs84.longitude
        ))
        XCTAssertFalse(pair.matchesWGS84(latitude: gcj.latitude, longitude: gcj.longitude))
    }

    func testCoordinateRepresentationDiagnosisDistinguishesDomesticPair() {
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.539,
            lon: 113.934,
            mapCoordinateSystem: .wgs84
        )

        XCTAssertEqual(
            CoordinateConverter.diagnoseRepresentation(sample: pair.wgs84.coordinate, pair: pair).inferredSystem,
            .wgs84
        )
        XCTAssertEqual(
            CoordinateConverter.diagnoseRepresentation(sample: pair.gcj02.coordinate, pair: pair).inferredSystem,
            .gcj02
        )
    }

    func testCoordinateRepresentationDiagnosisKeepsOverseasIdentityPairAmbiguous() {
        let pair = CoordinateConverter.coordinatePair(
            lat: 48.858_37,
            lon: 2.294_481,
            mapCoordinateSystem: .wgs84
        )

        XCTAssertNil(
            CoordinateConverter.diagnoseRepresentation(sample: pair.wgs84.coordinate, pair: pair).inferredSystem
        )
    }

    func testCoordinateRepresentationDiagnosisRejectsUnrelatedSample() {
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.539,
            lon: 113.934,
            mapCoordinateSystem: .wgs84
        )
        let unrelated = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)

        XCTAssertNil(CoordinateConverter.diagnoseRepresentation(sample: unrelated, pair: pair).inferredSystem)
    }

    func testMapConfigurationNeverRequestsRealUserLocation() {
        XCTAssertFalse(MapConfiguration.default.showsUserLocation)
        XCTAssertFalse(MapConfiguration.default.allowsCurrentLocationRequest)
    }

    func testExportThenImportMergesByWGS84AndPreservesTypedPair() throws {
        let sourceSuite = "FavoriteTransferSource.\(UUID().uuidString)"
        let destinationSuite = "FavoriteTransferDestination.\(UUID().uuidString)"
        let sourceDefaults = UserDefaults(suiteName: sourceSuite)!
        let destinationDefaults = UserDefaults(suiteName: destinationSuite)!
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            destinationDefaults.removePersistentDomain(forName: destinationSuite)
        }

        let pair = CoordinateConverter.coordinatePair(
            lat: 22.544_577,
            lon: 113.941_14,
            mapCoordinateSystem: .gcj02
        )
        let source = FavoriteLocationStore(defaults: sourceDefaults)
        _ = source.save(name: "旧名称", coordinatePair: pair, accuracy: 25)
        let exported = try source.exportTransferred()
        let decoded = try FavoriteTransfer.decode(exported)
        XCTAssertEqual(decoded[0].coordinatePair, pair)

        let destination = FavoriteLocationStore(defaults: destinationDefaults)
        _ = destination.save(name: "旧名称", coordinatePair: pair, accuracy: 25)
        let extra = FavoriteLocation(
            name: "埃菲尔铁塔",
            coordinatePair: CoordinateConverter.coordinatePair(
                lat: 48.858_37,
                lon: 2.294_481,
                mapCoordinateSystem: .wgs84
            ),
            accuracy: 30
        )
        let renamed = FavoriteLocation(name: "深圳湾公园", coordinatePair: pair, accuracy: 15)
        let result = destination.importTransferred([renamed, extra])

        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(destination.favorites.count, 2)
        XCTAssertEqual(destination.favorites.first { $0.coordinatePair == pair }?.name, "深圳湾公园")
        XCTAssertEqual(destination.favorites.first { $0.coordinatePair == pair }?.accuracy, 15)
        XCTAssertEqual(destination.favorites.first { $0.name == "埃菲尔铁塔" }?.coordinatePair.wgs84.latitude ?? 0, 48.858_37, accuracy: 0.000_000_1)
    }

    func testTransferRejectsInvalidJSONAndMissingCoordinates() {
        XCTAssertThrowsError(try FavoriteTransfer.decode(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? FavoriteTransfer.TransferError, .invalidJSON)
        }

        let missingCoordinates = """
        {"format":"paopao-favorites","version":1,"favorites":[{"name":"残缺","accuracy":25,"createdAt":"2026-01-01T00:00:00Z","wgs84":{"latitude":22.54,"longitude":113.94}}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try FavoriteTransfer.decode(missingCoordinates)) { error in
            XCTAssertEqual(error as? FavoriteTransfer.TransferError, .missingCoordinates)
        }

        let empty = """
        {"format":"paopao-favorites","version":1,"favorites":[]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try FavoriteTransfer.decode(empty)) { error in
            XCTAssertEqual(error as? FavoriteTransfer.TransferError, .empty)
        }
    }

    func testDisplayedFavoritesFollowsPersistedSortOrder() {
        let suite = "FavoriteLocationStoreTests.sort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoriteLocationStore(defaults: defaults)
        _ = store.save(
            name: "Beijing",
            coordinatePair: CoordinateConverter.coordinatePair(
                lat: 39.904,
                lon: 116.407,
                mapCoordinateSystem: .gcj02
            ),
            accuracy: 20
        )
        _ = store.save(
            name: "Shanghai",
            coordinatePair: CoordinateConverter.coordinatePair(
                lat: 31.230,
                lon: 121.473,
                mapCoordinateSystem: .gcj02
            ),
            accuracy: 20
        )

        XCTAssertEqual(store.sortOrder, .recent)
        XCTAssertEqual(store.displayedFavorites.map(\.name), ["Shanghai", "Beijing"])

        store.setSortOrder(.name)
        XCTAssertEqual(store.displayedFavorites.map(\.name), ["Beijing", "Shanghai"])

        let reloaded = FavoriteLocationStore(defaults: defaults)
        XCTAssertEqual(reloaded.sortOrder, .name)
        XCTAssertEqual(reloaded.displayedFavorites.map(\.name), ["Beijing", "Shanghai"])

        reloaded.setSortOrder(.recent)
        XCTAssertEqual(reloaded.displayedFavorites.map(\.name), ["Shanghai", "Beijing"])
    }

}

private struct LegacyFavoritePayload: Encodable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Int
    let createdAt: Date
}
