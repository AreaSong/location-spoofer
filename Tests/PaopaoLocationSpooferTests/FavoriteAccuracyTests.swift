import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class FavoriteAccuracyTests: XCTestCase {
    private let invalidValues = [Int.min, -1, 0, 4, 101, Int(Int32.max), Int(Int32.max) + 1, Int.max]

    func testImportRejectsInvalidAccuracyWithoutChangingFavoritesOrSettings() throws {
        let suite = "FavoriteAccuracyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoriteLocationStore(defaults: defaults)
        store.save(name: "已有", coordinatePair: favorite(25).coordinatePair, accuracy: 25)
        defaults.set(try JSONEncoder().encode(WlocSettings(
            longitude: 1, latitude: 2, accuracy: 25, enabled: true
        )), forKey: WlocKeys.coords)
        let originalFavorites = defaults.data(forKey: "favorite_locations")
        let originalSettings = defaults.data(forKey: WlocKeys.coords)
        let originalSelection = store.selectedFavoriteID
        for accuracy in invalidValues {
            let data = try FavoriteTransfer.encode([favorite(27), favorite(accuracy)])
            XCTAssertThrowsError(try FavoriteTransfer.decode(data), "accuracy=\(accuracy)") {
                XCTAssertEqual($0 as? LocationAccuracy.ValidationError, .outOfRange(accuracy))
            }
            XCTAssertThrowsError(try store.importTransferred([favorite(27), favorite(accuracy)]))
            XCTAssertEqual(store.favorites.first?.accuracy, 25)
            XCTAssertEqual(store.selectedFavoriteID, originalSelection)
            XCTAssertEqual(defaults.data(forKey: "favorite_locations"), originalFavorites)
            XCTAssertEqual(defaults.data(forKey: WlocKeys.coords), originalSettings)
        }
    }

    func testEveryIntegerInProductRangeImportsAndAppliesExactly() async throws {
        for accuracy in 5...100 {
            let decoded = try FavoriteTransfer.decode(FavoriteTransfer.encode([favorite(accuracy)]))
            XCTAssertEqual(decoded.first?.accuracy, accuracy)
            let proxy = AccuracyProxy()
            let settings = AccuracySettings()
            let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
            let applied = await coordinator.apply(decoded[0])
            XCTAssertTrue(applied)
            XCTAssertEqual(proxy.accuracies, [accuracy])
            XCTAssertEqual(settings.saved?.accuracy, accuracy)
        }
    }

    func testMalformedAccuracyKeepsExistingJSONContract() throws {
        let data = try FavoriteTransfer.encode([favorite(25)])
        for value in ["1.5", "null", "\"25\""] {
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\"accuracy\" : 25", with: "\"accuracy\" : \(value)")
            XCTAssertThrowsError(try FavoriteTransfer.decode(text: text)) {
                XCTAssertEqual($0 as? FavoriteTransfer.TransferError, .invalidJSON)
            }
        }
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(document["favorites"] as? [[String: Any]])
        items[0].removeValue(forKey: "accuracy")
        document["favorites"] = items
        XCTAssertThrowsError(try FavoriteTransfer.decode(JSONSerialization.data(withJSONObject: document))) {
            XCTAssertEqual($0 as? FavoriteTransfer.TransferError, .invalidJSON)
        }
    }

    func testInvalidApplyDoesNotStartProxyOrSaveSettings() async {
        for accuracy in invalidValues {
            let proxy = AccuracyProxy()
            let settings = AccuracySettings()
            let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
            let applied = await coordinator.apply(favorite(accuracy))
            XCTAssertFalse(applied)
            XCTAssertEqual(proxy.starts, 0)
            XCTAssertTrue(proxy.accuracies.isEmpty)
            XCTAssertNil(settings.saved)
            XCTAssertFalse(coordinator.virtualLocationEnabled)
        }
    }

    func testInvalidVerifiedAndMovementWritesPreservePreviousSuccess() async {
        for accuracy in invalidValues {
            let proxy = AccuracyProxy()
            let settings = AccuracySettings()
            let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
            _ = await coordinator.apply(favorite(25))
            let saved = settings.saved
            XCTAssertNil(coordinator.applyVerified(favorite(accuracy)))
            XCTAssertFalse(coordinator.updateSpoofedWGS84(latitude: 8, longitude: 9, accuracy: accuracy))
            XCTAssertEqual(proxy.accuracies, [25])
            XCTAssertEqual(settings.saved?.latitude, saved?.latitude)
            XCTAssertEqual(settings.saved?.accuracy, 25)
            XCTAssertTrue(coordinator.virtualLocationEnabled)
        }
    }

    func testIslandShortcutWithHistoricalBadAccuracyFailsBeforeVerification() async throws {
        let suite = "HistoricalFavoriteAccuracy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = favorite(Int.max)
        let bytes = try JSONEncoder().encode([old])
        defaults.set(bytes, forKey: "favorite_locations")
        let store = FavoriteLocationStore(defaults: defaults)
        let command = IslandFavoriteCommand.action(for: old.id)
        let id = try XCTUnwrap(IslandFavoriteCommand.favoriteID(from: command))
        let target = try XCTUnwrap(store.favorites.first { $0.id == id })
        let probe = SpoofServiceProbe()
        let proxy = AccuracyProxy()
        let settings = AccuracySettings()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
        var services = probe.services()
        services.applyVerified = { coordinator.applyVerified($0) }
        services.verify = { probe.verifyCount += 1; return .success }
        let session = SpoofSession(state: .active, writtenLatitude: 1, writtenLongitude: 2)
        session.bind(services)

        session.begin(target: target)
        await session.waitForOperation()

        XCTAssertEqual(target.accuracy, Int.max)
        XCTAssertEqual(probe.verifyCount, 0)
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.writtenLatitude, 1)
        XCTAssertEqual(session.writtenLongitude, 2)
        XCTAssertFalse(session.consumeEffects().contains(.activationSucceeded))
        XCTAssertEqual(defaults.data(forKey: "favorite_locations"), bytes)
        XCTAssertTrue(proxy.accuracies.isEmpty)
        XCTAssertNil(settings.saved)
    }

    func testImportedIslandShortcutPassesOriginalAccuracyThroughSessionAndCoordinator() async throws {
        let suite = "ImportedIslandAccuracy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FavoriteLocationStore(defaults: defaults)
        try store.importTransferred(FavoriteTransfer.decode(FavoriteTransfer.encode([favorite(27)])))
        let imported = try XCTUnwrap(store.favorites.first)
        let id = IslandFavoriteCommand.favoriteID(from: IslandFavoriteCommand.action(for: imported.id))
        let target = try XCTUnwrap(store.favorites.first { $0.id == id })
        let proxy = AccuracyProxy()
        let settings = AccuracySettings()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
        let probe = SpoofServiceProbe()
        var services = probe.services()
        services.verify = { try? await proxy.start(); return .success }
        services.applyVerified = { coordinator.applyVerified($0) }
        let session = SpoofSession()
        session.bind(services)
        var appliedTarget: FavoriteLocation?
        IslandFavoriteShortcuts.performSwitch(to: target, action: IslandFavoriteCommand.action(for: target.id)) {
            appliedTarget = $0
            session.begin(target: $0)
        } reject: { _, message in
            XCTFail(message)
        }
        await session.waitForOperation()
        XCTAssertEqual(appliedTarget, target)
        XCTAssertEqual(proxy.accuracies, [27])
        XCTAssertEqual(settings.saved?.accuracy, 27)
        XCTAssertEqual(session.writtenLatitude, target.latitude)
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(session.consumeEffects().contains(.activationSucceeded))
    }

    func testInvalidIslandShortcutRejectsBeforeSelectionAndKeepsOriginalRetryCommand() {
        let target = favorite(Int.max)
        let action = IslandFavoriteCommand.action(for: target.id)
        var applied = false
        var retryCommand = ""
        var failureMessage = ""
        var command = action
        for _ in 0..<2 {
            IslandFavoriteShortcuts.performSwitch(to: target, action: command) { _ in
                // 真实入口把选点、停止走动和 session.begin 都放在此成功分支内。
                applied = true
            } reject: { command, message in
                retryCommand = command
                failureMessage = message
            }
            XCTAssertFalse(applied)
            XCTAssertEqual(retryCommand, action)
            XCTAssertEqual(IslandFavoriteCommand.favoriteID(from: retryCommand), target.id)
            XCTAssertEqual(failureMessage, LocationAccuracy.ValidationError.outOfRange(Int.max).localizedDescription)
            command = retryCommand
        }
    }

    func testBridgeFailureDoesNotPersistOrReplaceSessionSuccess() async {
        let proxy = AccuracyProxy()
        let settings = AccuracySettings()
        let coordinator = LocationActionCoordinator(proxy: proxy, settings: settings)
        _ = await coordinator.apply(favorite(25))
        proxy.writeError = ProxyError.startFailed
        let probe = SpoofServiceProbe()
        var services = probe.services()
        services.applyVerified = { coordinator.applyVerified($0) }
        services.localSpoofEnabled = { coordinator.virtualLocationEnabled }
        services.localApplyFailureMessage = { coordinator.message }
        let session = SpoofSession(state: .active, writtenLatitude: 1, writtenLongitude: 2)
        session.bind(services)
        session.begin(target: favorite(27))
        await session.waitForOperation()
        XCTAssertEqual(settings.saved?.accuracy, 25)
        XCTAssertEqual(proxy.accuracies, [25])
        XCTAssertTrue(coordinator.virtualLocationEnabled)
        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.writtenLongitude, 2)
        XCTAssertEqual(session.consumeEffects(), [.locationApplyFailed(coordinator.message)])
    }

    func testHistoricalBadSettingsDoNotClaimEnabled() {
        let settings = AccuracySettings()
        settings.saved = WlocSettings(longitude: 1, latitude: 2, accuracy: Int.max, enabled: true)
        let coordinator = LocationActionCoordinator(proxy: AccuracyProxy(), settings: settings)
        XCTAssertFalse(coordinator.virtualLocationEnabled)
        XCTAssertEqual(settings.saved?.accuracy, Int.max)
    }

    private func favorite(_ accuracy: Int) -> FavoriteLocation {
        FavoriteLocation(name: "合成点", coordinatePair: CoordinateConverter.coordinatePair(
            lat: 1, lon: 2, mapCoordinateSystem: .wgs84
        ), accuracy: accuracy)
    }
}

@MainActor
private final class AccuracyProxy: LocationActionProxying {
    var isRunning = false
    var starts = 0
    var accuracies: [Int] = []
    var writeError: Error?
    func start() async throws { starts += 1; isRunning = true }
    func setCoords(lat: Double, lon: Double, enabled: Bool, accuracy: Int) throws -> UInt64 {
        if let writeError { throw writeError }
        accuracies.append(accuracy)
        return UInt64(accuracies.count)
    }
}

@MainActor
private final class AccuracySettings: LocationActionSettingsStoring {
    var saved: WlocSettings?
    func load() -> WlocSettings? { saved }
    func save(_ settings: WlocSettings) { saved = settings }
    func clear() { saved = nil }
}
