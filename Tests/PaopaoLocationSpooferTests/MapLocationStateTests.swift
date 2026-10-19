import Combine
import XCTest
import CoreLocation
import MapKit
@testable import PaopaoLocationSpoofer

@MainActor
final class MapLocationStateTests: XCTestCase {
    private let initial = CLLocationCoordinate2D(latitude: 22.544577, longitude: 113.94114)

    func testStaleRealtimeResultDoesNotReplaceNewerMapPan() {
        let state = MapLocationState(initialCoordinate: initial)
        let request = state.beginRealtimeIntent()

        state.selectUserMapCenter(.init(latitude: 31.23, longitude: 121.47))
        let accepted = state.acceptRealtimeLocation(
            .init(latitude: 39.90, longitude: 116.40),
            intent: request
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(state.selection.coordinate.latitude, 31.23, accuracy: 0.000001)
        XCTAssertEqual(state.realtimeCoordinate?.latitude ?? 0, 39.90, accuracy: 0.000001)
    }

    func testSearchAndFavoriteSelectionsOwnTheirNamesAndRevision() {
        let state = MapLocationState(initialCoordinate: initial)
        let originalRevision = state.selection.revision
        let favoriteID = UUID()

        state.selectSearchResult(.init(latitude: 31.23, longitude: 121.47), name: "外滩")
        XCTAssertGreaterThan(state.selection.revision, originalRevision)
        XCTAssertEqual(state.selection.source, .search)
        XCTAssertEqual(state.displayName, "外滩")

        state.selectFavorite(.init(latitude: 39.90, longitude: 116.40), id: favoriteID, name: "公司")
        XCTAssertEqual(state.selection.source, .favorite(favoriteID))
        XCTAssertEqual(state.displayName, "公司")

        state.updateViewport(distanceMeters: 300_000)
        XCTAssertEqual(state.displayName, "公司")
    }

    func testPanTapAndRealtimeClearOldFavoriteOwnership() {
        let state = MapLocationState(initialCoordinate: initial)
        state.selectFavorite(initial, id: UUID(), name: "旧收藏")

        state.selectMapTap(.init(latitude: 23, longitude: 114))
        XCTAssertEqual(state.selection.source, .mapTap)
        XCTAssertNil(state.selection.explicitName)

        state.selectUserMapCenter(.init(latitude: 24, longitude: 115))
        XCTAssertEqual(state.selection.source, .userPan)

        let intent = state.beginRealtimeIntent()
        XCTAssertTrue(state.acceptRealtimeLocation(.init(latitude: 25, longitude: 116), intent: intent))
        XCTAssertEqual(state.selection.source, .realtime)
    }


    func testUnchangedUserCenterDoesNotClearExplicitSearchName() {
        let state = MapLocationState(initialCoordinate: initial)
        state.selectSearchResult(initial, name: "深圳湾")
        let revision = state.selection.revision

        let returnedRevision = state.selectUserMapCenter(initial)

        XCTAssertEqual(returnedRevision, revision)
        XCTAssertEqual(state.selection.source, .search)
        XCTAssertEqual(state.displayName, "深圳湾")
    }

    func testRepeatedFocusCommandsHaveUniqueIDs() {
        let state = MapLocationState(initialCoordinate: initial)
        state.focusSelection(distanceMeters: 200)
        let first = state.cameraCommand
        state.focusSelection(distanceMeters: 200)
        let second = state.cameraCommand

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testZoomCommandDoesNotChangeSelectedCoordinate() {
        let state = MapLocationState(initialCoordinate: initial)
        let before = state.selection
        state.zoom(by: 0.5)

        XCTAssertEqual(state.selection.coordinate.latitude, before.coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(state.selection.coordinate.longitude, before.coordinate.longitude, accuracy: 0.000001)
        guard case .zoom(let factor) = state.cameraCommand?.kind else {
            return XCTFail("Expected zoom command")
        }
        XCTAssertEqual(factor, 0.5)
    }

    func testFitRouteCommandKeepsSelectionAndUsesAllCoordinates() {
        let state = MapLocationState(initialCoordinate: initial)
        let before = state.selection
        let start = CLLocationCoordinate2D(latitude: 22.494, longitude: 113.951)
        let end = CLLocationCoordinate2D(latitude: 22.496, longitude: 113.954)
        state.fitRoute([start, end])

        XCTAssertEqual(state.selection.coordinate.latitude, before.coordinate.latitude, accuracy: 0.000001)
        guard case let .fit(coordinates) = state.cameraCommand?.kind else {
            return XCTFail("Expected fit command")
        }
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(coordinates[1].latitude, end.latitude, accuracy: 0.000001)
    }

    func testPlaceLabelChangesWithViewportDistance() {
        let place = MapPlaceDescriptor(
            pointOfInterest: "深圳湾体育中心",
            streetAddress: "滨海大道 3001 号",
            road: "滨海大道",
            neighborhood: "粤海街道",
            district: "南山区",
            city: "深圳市",
            province: "广东省",
            country: "中国"
        )

        XCTAssertEqual(place.displayName(viewportMeters: 300), "深圳湾体育中心")
        XCTAssertEqual(place.displayName(viewportMeters: 2_500), "滨海大道")
        XCTAssertEqual(place.displayName(viewportMeters: 8_000), "粤海街道")
        XCTAssertEqual(place.displayName(viewportMeters: 15_000), "南山区 · 深圳市")
        XCTAssertEqual(place.displayName(viewportMeters: 300_000), "深圳市 · 广东省")
    }

    func testDistrictFallbackStillChangesBetweenNeighborhoodAndCityZoom() {
        let place = MapPlaceDescriptor(
            pointOfInterest: "深圳湾公园",
            streetAddress: "望海路 1 号",
            road: "望海路",
            district: "南山区",
            city: "深圳市",
            province: "广东省",
            country: "中国"
        )

        XCTAssertEqual(place.displayName(viewportMeters: 8_000), "南山区")
        XCTAssertEqual(place.displayName(viewportMeters: 15_000), "南山区 · 深圳市")
        XCTAssertEqual(place.displayName(viewportMeters: 300_000), "深圳市 · 广东省")
    }

    func testPlaceLabelFallsBackAcrossMissingLevels() {
        let place = MapPlaceDescriptor(
            pointOfInterest: nil,
            streetAddress: nil,
            neighborhood: "科技园社区",
            district: nil,
            city: "深圳市",
            province: "广东省",
            country: "中国"
        )

        XCTAssertEqual(place.displayName(viewportMeters: 300), "科技园社区")
        XCTAssertEqual(place.displayName(viewportMeters: 15_000), "深圳市")
        XCTAssertEqual(place.displayName(viewportMeters: 300_000), "深圳市 · 广东省")
    }

    func testStaleGeocodeCannotReplaceCurrentDescriptor() {
        let state = MapLocationState(initialCoordinate: initial)
        let staleRevision = state.selection.revision
        state.selectUserMapCenter(.init(latitude: 31.23, longitude: 121.47))

        let accepted = state.acceptPlaceDescriptor(
            MapPlaceDescriptor(city: "旧城市"),
            selectionRevision: staleRevision
        )

        XCTAssertFalse(accepted)
        XCTAssertNil(state.placeDescriptor)
    }


    func testNativeRealtimeUpdateDoesNotMoveCurrentSelection() {
        let state = MapLocationState(initialCoordinate: initial)
        state.selectSearchResult(.init(latitude: 31.23, longitude: 121.47), name: "外滩")
        let revision = state.selection.revision

        state.updateRealtimeLocation(CLLocation(latitude: 30.42, longitude: 114.25))

        XCTAssertEqual(state.realtimeCoordinate?.latitude ?? 0, 30.42, accuracy: 0.000001)
        XCTAssertEqual(state.selection.coordinate.latitude, 31.23, accuracy: 0.000001)
        XCTAssertEqual(state.selection.revision, revision)
        XCTAssertEqual(state.selection.source, .search)
    }

    func testUnchangedViewportDoesNotPublish() {
        let state = MapLocationState(initialCoordinate: initial, initialViewportMeters: 2_000)
        var publishes = 0
        let token = state.objectWillChange.sink { publishes += 1 }

        state.updateViewport(distanceMeters: 2_000)
        XCTAssertEqual(publishes, 0)

        state.updateViewport(distanceMeters: 3_000)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(state.viewportMeters, 3_000)
        token.cancel()
    }

    private func makePanCoordinator(
        onCenter: @escaping (CLLocationCoordinate2D) -> Void,
        onViewport: @escaping () -> Void = {}
    ) -> MapViewRepresentable.Coordinator {
        MapViewRepresentable(
            selection: .init(coordinate: initial, source: .initial, explicitName: nil, revision: 0),
            initialViewportMeters: 2_000, cameraCommand: nil,
            onRealtimeLocationChanged: { _ in },
            onUserCenterChanged: { center, _ in onCenter(center) },
            onViewportChanged: { _ in onViewport() },
            onMapTap: { _ in }, onUserZoomChanged: nil
        ).makeCoordinator()
    }

    private func waitPastPanSettle() {
        let settled = expectation(description: "pan settle window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + MapViewRepresentable.Coordinator.panSettleDelay + 0.2) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
    }

    func testFinishingPanCommitsSelectionOnlyAfterSettleWindow() {
        var centers: [CLLocationCoordinate2D] = []
        var viewportUpdates = 0
        let coordinator = makePanCoordinator(onCenter: { centers.append($0) }, onViewport: { viewportUpdates += 1 })
        let center = CLLocationCoordinate2D(latitude: 31.2181, longitude: 121.4556)

        coordinator.finishUserPan(center: center, distance: 2_000)
        // 地图刚停下不立刻判定：两手交替滑时下一划可能马上开始。
        XCTAssertTrue(centers.isEmpty)
        XCTAssertEqual(viewportUpdates, 0)

        waitPastPanSettle()
        XCTAssertEqual(centers.count, 1)
        XCTAssertEqual(centers.first?.latitude ?? 0, center.latitude, accuracy: 1e-9)
        XCTAssertEqual(centers.first?.longitude ?? 0, center.longitude, accuracy: 1e-9)
    }

    func testAlternatingPansCommitOnlyTheLastStop() {
        var centers: [CLLocationCoordinate2D] = []
        let coordinator = makePanCoordinator(onCenter: { centers.append($0) })
        let right = CLLocationCoordinate2D(latitude: 31.20, longitude: 121.40)
        let left = CLLocationCoordinate2D(latitude: 31.25, longitude: 121.50)

        coordinator.finishUserPan(center: right, distance: 2_000)
        // 换手：下一划开始时丢弃上一划的待提交结果。
        coordinator.cancelPendingPanCommit()
        coordinator.finishUserPan(center: left, distance: 2_000)

        waitPastPanSettle()
        XCTAssertEqual(centers.count, 1)
        XCTAssertEqual(centers.first?.latitude ?? 0, left.latitude, accuracy: 1e-9)
    }

    func testTapFlushesPendingPanBeforeItsOwnSelection() {
        var centers: [CLLocationCoordinate2D] = []
        let coordinator = makePanCoordinator(onCenter: { centers.append($0) })
        let center = CLLocationCoordinate2D(latitude: 31.2181, longitude: 121.4556)
        coordinator.finishUserPan(center: center, distance: 2_000)

        coordinator.flushPendingPanCommit(synchronously: true)

        // 点按前必须已经提交，点按产生的新选点才会排在后面。
        XCTAssertEqual(centers.count, 1)
        waitPastPanSettle()
        XCTAssertEqual(centers.count, 1, "提交后不能再按计时器重复提交")
    }

    func testFocusCommandDiscardsPendingPanButZoomCommitsIt() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        var centers: [CLLocationCoordinate2D] = []
        let coordinator = makePanCoordinator(onCenter: { centers.append($0) })
        let panned = CLLocationCoordinate2D(latitude: 31.2181, longitude: 121.4556)

        coordinator.finishUserPan(center: panned, distance: 2_000)
        coordinator.consume(MapCameraCommand(id: 1, kind: .focus(coordinate: initial, distanceMeters: 2_000)), on: map)
        waitPastPanSettle()
        // 选了收藏或搜索结果：新选点优先，旧的拖动位置不能覆盖它。
        XCTAssertTrue(centers.isEmpty)

        coordinator.finishUserPan(center: panned, distance: 2_000)
        coordinator.consume(MapCameraCommand(id: 2, kind: .zoom(factor: 0.5)), on: map)
        let zoomed = expectation(description: "pan committed before zoom settles")
        DispatchQueue.main.async {
            // 缩放只改视野：拖动位置立即提交，不等缓冲期。
            XCTAssertEqual(centers.count, 1)
            zoomed.fulfill()
        }
        wait(for: [zoomed], timeout: 1)
    }

    func testSuspendedRealtimeCatchesUpWithoutPublishingPerSample() {
        let state = MapLocationState(initialCoordinate: initial)
        state.updateRealtimeLocation(CLLocation(latitude: 30.42, longitude: 114.25))
        var publishes = 0
        let token = state.objectWillChange.sink { publishes += 1 }
        state.setPublishesRealtime(false)
        state.updateRealtimeLocation(CLLocation(latitude: 31.23, longitude: 121.47))
        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(state.realtimeCoordinate?.latitude ?? 0, 30.42, accuracy: 0.000001)

        state.setPublishesRealtime(true)
        XCTAssertEqual(state.realtimeCoordinate?.latitude ?? 0, 31.23, accuracy: 0.000001)
        // 蓝点一直存在，只是换了位置：首页不因此重算。
        XCTAssertEqual(publishes, 0)
        token.cancel()
    }

    func testRealtimeSamplesPublishOnlyWhenBluePointAppearsOrDisappears() {
        let state = MapLocationState(initialCoordinate: initial)
        var publishes = 0
        let token = state.objectWillChange.sink { publishes += 1 }

        state.updateRealtimeLocation(CLLocation(latitude: 31.2304, longitude: 121.4737))
        XCTAssertTrue(state.hasRealtimeCoordinate)
        XCTAssertEqual(publishes, 1)

        // GPS 每秒一个样本：位置在变，但不能每秒让首页整页重算。
        for step in 1...5 {
            state.updateRealtimeLocation(CLLocation(
                coordinate: .init(latitude: 31.2304 + Double(step) * 0.0001, longitude: 121.4737),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                timestamp: Date().addingTimeInterval(Double(step))
            ))
        }
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(state.realtimeCoordinate?.latitude ?? 0, 31.2309, accuracy: 0.000001)

        state.clearRealtimeLocationForMapCoordinateSystemChange()
        XCTAssertFalse(state.hasRealtimeCoordinate)
        XCTAssertEqual(publishes, 2)
        token.cancel()
    }

    func testWalkPuckFollowsLatestBluePointInsteadOfStaleRenderValue() throws {
        let stale = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let latest = CLLocationCoordinate2D(latitude: 31.2404, longitude: 121.4837)
        let parent = MapViewRepresentable(
            selection: .init(coordinate: initial, source: .initial, explicitName: nil, revision: 0),
            initialViewportMeters: 2_000, cameraCommand: nil,
            onRealtimeLocationChanged: { _ in }, onUserCenterChanged: { _, _ in },
            onViewportChanged: { _ in }, onMapTap: { _ in }, onUserZoomChanged: nil,
            walkHeading: PhysicalWalkHeadingFeed(degrees: 90),
            walkPuckCoordinate: stale,
            walkPuckFollowsUserLocation: true,
            showsWalkHeading: true
        )
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let coordinator = parent.makeCoordinator()
        coordinator.installWalkHeadingHud(on: map)
        coordinator.refreshLocationPuck(on: map)

        coordinator.followUserLocation(latest)
        XCTAssertEqual(coordinator.puckCoordinate?.latitude ?? 0, latest.latitude, accuracy: 1e-9)

        // 别的状态触发首页重算时，parent 里还是旧蓝点，扇形不能被拉回去。
        coordinator.refreshLocationPuck(on: map)
        XCTAssertEqual(coordinator.puckCoordinate?.latitude ?? 0, latest.latitude, accuracy: 1e-9)
        coordinator.stopWalkPuckTracking()
    }

    func testMapCoordinateSystemChangeClearsSupersededRealtimeSampleWithoutMovingSelection() {
        let state = MapLocationState(initialCoordinate: initial)
        state.selectSearchResult(.init(latitude: 31.23, longitude: 121.47), name: "外滩")
        let selection = state.selection
        state.updateRealtimeLocation(CLLocation(latitude: 30.42, longitude: 114.25))

        state.clearRealtimeLocationForMapCoordinateSystemChange()

        XCTAssertNil(state.realtimeLocation)
        XCTAssertNil(state.realtimeCoordinate)
        XCTAssertEqual(state.selection, selection)
    }

    func testRealtimeIntentCanImmediatelyAcceptNativeLocation() {
        let state = MapLocationState(initialCoordinate: initial)
        let nativeLocation = CLLocation(latitude: 30.42, longitude: 114.25)
        state.updateRealtimeLocation(nativeLocation)
        let intent = state.beginRealtimeIntent()

        XCTAssertTrue(state.acceptRealtimeLocation(nativeLocation.coordinate, intent: intent))
        XCTAssertEqual(state.selection.source, .realtime)
        XCTAssertEqual(state.selection.coordinate.latitude, 30.42, accuracy: 0.000001)
        XCTAssertNil(state.cameraCommand, "realtime updates preserve the current camera unless the caller explicitly focuses it")
    }

    func testMapCoordinateSystemReprojectionPreservesSelectionIdentityAndIssuesFocus() {
        let state = MapLocationState(initialCoordinate: initial)
        let favoriteID = UUID()
        state.selectFavorite(.init(latitude: 22.55, longitude: 113.95), id: favoriteID, name: "测试收藏")
        let revision = state.selection.revision

        state.reprojectSelectionForMapCoordinateSystemChange(.init(latitude: 22.54, longitude: 113.94))

        XCTAssertEqual(state.selection.source, .favorite(favoriteID))
        XCTAssertEqual(state.selection.explicitName, "测试收藏")
        XCTAssertEqual(state.selection.revision, revision)
        XCTAssertEqual(state.selection.coordinate.latitude, 22.54, accuracy: 0.000001)
        guard case let .focus(coordinate, distanceMeters) = state.cameraCommand?.kind else {
            return XCTFail("Expected a focus command after map coordinate-system reprojection")
        }
        XCTAssertEqual(coordinate.latitude, 22.54, accuracy: 0.000001)
        XCTAssertEqual(distanceMeters, state.viewportMeters)
    }

    func testZoomMathScalesBothAxesInTheSameDirection() {
        let span = MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.1)

        let zoomedIn = MapZoomMath.scaledSpan(span, factor: 0.5)
        XCTAssertEqual(zoomedIn.latitudeDelta, 0.1, accuracy: 0.000001)
        XCTAssertEqual(zoomedIn.longitudeDelta, 0.05, accuracy: 0.000001)

        let zoomedOut = MapZoomMath.scaledSpan(span, factor: 2)
        XCTAssertEqual(zoomedOut.latitudeDelta, 0.4, accuracy: 0.000001)
        XCTAssertEqual(zoomedOut.longitudeDelta, 0.2, accuracy: 0.000001)
    }

    func testViewportScaleLabelUsesReadableMetricUnits() {
        XCTAssertEqual(MapZoomMath.viewportScaleLabel(distanceMeters: 180), "180 m")
        XCTAssertEqual(MapZoomMath.viewportScaleLabel(distanceMeters: 2_500), "2.5 km")
        XCTAssertEqual(MapZoomMath.viewportScaleLabel(distanceMeters: 126_000), "126 km")
    }

    func testLastCoordinateStoreKeepsBothFormsAndZoom() {
        let suite = "MapLocationStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gcj = CLLocationCoordinate2D(latitude: 22.544_577, longitude: 113.941_14)

        LastCoordinateStore.save(mapCoordinate: gcj, mapCoordinateSystem: .gcj02, zoomMeters: 1_250, defaults: defaults)

        guard let restored = LastCoordinateStore.load(defaults: defaults) else {
            return XCTFail("Expected a persisted current map pin")
        }
        XCTAssertEqual(restored.coordinate(for: .gcj02).latitude, gcj.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(restored.coordinate(for: .gcj02).longitude, gcj.longitude, accuracy: 0.000_000_1)
        XCTAssertNotEqual(restored.coordinate(for: .wgs84).longitude, gcj.longitude)
        XCTAssertEqual(restored.zoomMeters, 1_250)
    }

    func testCoordinateMigrationUpgradesLegacyCurrentPinAndFavoritesBeforeSettingVersion() throws {
        let suite = "MapLocationStateTests.\(UUID().uuidString)"
        let legacySuite = "MapLocationStateTests.Legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        let firstID = UUID()
        let secondID = UUID()
        let records = [
            CoordinateMigrationLegacyFavorite(id: firstID, name: "第一个", latitude: 22.544_577, longitude: 113.941_14, accuracy: 15, createdAt: .distantPast),
            CoordinateMigrationLegacyFavorite(id: secondID, name: "海外", latitude: 48.858_37, longitude: 2.294_481, accuracy: 30, createdAt: .distantFuture),
        ]
        legacyDefaults.set(22.544_577, forKey: "lastMapLat")
        legacyDefaults.set(113.941_14, forKey: "lastMapLon")
        legacyDefaults.set(2_000.0, forKey: "mapViewportMeters")
        defaults.set(try JSONEncoder().encode(records), forKey: "favorite_locations")
        defaults.set(secondID.uuidString, forKey: "favorite_locations_selected_id")

        let favorites = FavoriteLocationStore(defaults: defaults)
        try CoordinateStorageMigration.migrateIfNeeded(
            favorites: favorites,
            defaults: defaults,
            legacyDefaults: legacyDefaults
        )

        XCTAssertEqual(defaults.integer(forKey: "coordinateStorageMigrationVersion"), CoordinateStorageMigration.currentVersion)
        guard let current = LastCoordinateStore.load(defaults: defaults) else {
            return XCTFail("Expected migrated current map pin")
        }
        XCTAssertEqual(current.coordinate(for: .gcj02).latitude, 22.544_577, accuracy: 0.000_000_1)
        XCTAssertEqual(current.zoomMeters, 2_000)

        let reloaded = FavoriteLocationStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.map(\.id), [firstID, secondID])
        XCTAssertEqual(reloaded.favorites.map(\.name), ["第一个", "海外"])
        XCTAssertEqual(reloaded.selectedFavoriteID, secondID)
        XCTAssertFalse(reloaded.favorites.contains(where: \.isLegacyCoordinateRecord))
        XCTAssertEqual(reloaded.favorites[1].coordinatePair.wgs84.latitude, reloaded.favorites[1].coordinatePair.gcj02.latitude, accuracy: 0.000_000_1)
    }

    func testWalkHeadingFanPathIsNonEmptyAndChangesWithHeading() {
        let bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        let north = WalkHeadingHud.fanPath(
            in: bounds,
            headingDegrees: 0,
            radius: 36,
            spreadDegrees: 70
        )
        let east = WalkHeadingHud.fanPath(
            in: bounds,
            headingDegrees: 90,
            radius: 36,
            spreadDegrees: 70
        )
        XCTAssertFalse(north.boundingBoxOfPath.isNull)
        XCTAssertGreaterThan(north.boundingBoxOfPath.width, 1)
        XCTAssertNotEqual(north.boundingBoxOfPath, east.boundingBoxOfPath)
    }
}

private struct CoordinateMigrationLegacyFavorite: Encodable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Int
    let createdAt: Date
}
