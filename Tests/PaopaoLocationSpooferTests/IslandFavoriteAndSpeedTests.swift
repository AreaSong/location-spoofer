import XCTest
@testable import PaopaoLocationSpoofer

final class IslandFavoriteAndSpeedTests: XCTestCase {
    func testFavoriteShortcutsExcludeCurrentSpoofAndYieldToSwitchHere() {
        let current = favorite("当前点", lat: 22.494, lon: 113.951)
        let selected = favorite("选中点", lat: 22.5, lon: 114)
        let extra = favorite("另一个", lat: 22.6, lon: 114.1)
        let displayed = [current, selected, extra]

        let locating = IslandFavoriteShortcuts.pick(
            from: displayed,
            selectedID: selected.id,
            writtenLatitude: current.latitude,
            writtenLongitude: current.longitude,
            currentSelection: current.coordinatePair,
            needsSwitch: false
        )
        XCTAssertEqual(locating.map(\.id), [selected.id, extra.id])

        let switching = IslandFavoriteShortcuts.pick(
            from: displayed,
            selectedID: selected.id,
            writtenLatitude: current.latitude,
            writtenLongitude: current.longitude,
            currentSelection: selected.coordinatePair,
            needsSwitch: true
        )
        XCTAssertEqual(switching.map(\.id), [extra.id])
        XCTAssertEqual(switching.count, 1)
    }

    func testFavoriteShortcutsPreferSelectedThenDisplayedOrder() {
        let first = favorite("甲", lat: 22.1, lon: 113.1)
        let second = favorite("乙", lat: 22.2, lon: 113.2)
        let third = favorite("丙", lat: 22.3, lon: 113.3)
        let picked = IslandFavoriteShortcuts.pick(
            from: [first, second, third],
            selectedID: third.id,
            writtenLatitude: 22.0,
            writtenLongitude: 113.0,
            currentSelection: first.coordinatePair,
            needsSwitch: false
        )
        XCTAssertEqual(picked.map(\.id), [third.id, first.id])
    }

    func testSpotLiveButtonsFillUpToThreeSlots() {
        let favA = IslandFavoriteCommand.action(for: UUID())
        let favB = IslandFavoriteCommand.action(for: UUID())
        let locating = SpotActivitySync.liveButtons(
            switchHere: false,
            shortcuts: [(favA, "甲"), (favB, "乙")]
        )
        XCTAssertEqual(locating.primaryAction, favA)
        XCTAssertEqual(locating.secondaryAction, favB)
        XCTAssertEqual(locating.tertiaryAction, "stopSpoof")

        let switching = SpotActivitySync.liveButtons(
            switchHere: true,
            shortcuts: [(favA, "甲"), (favB, "乙")]
        )
        XCTAssertEqual(switching.primaryAction, "switchHere")
        XCTAssertEqual(switching.secondaryAction, favA)
        XCTAssertEqual(switching.tertiaryAction, "stopSpoof")
        XCTAssertNotEqual(switching.secondaryAction, favB)
    }

    func testSpotSnapshotLocatingKeepsFavoriteShortcuts() {
        let favA = IslandFavoriteCommand.action(for: UUID())
        let snapshot = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: true,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            shortcuts: [(favA, "甲"), (IslandFavoriteCommand.action(for: UUID()), "乙")]
        )
        XCTAssertEqual(snapshot?.status, .locating)
        XCTAssertEqual(snapshot?.primaryAction, favA)
        XCTAssertEqual(snapshot?.tertiaryAction, "stopSpoof")
        let normalized = SpotActivitySync.normalized(snapshot!)
        XCTAssertEqual(normalized.primaryAction, favA)
        XCTAssertEqual(normalized.tertiaryAction, "stopSpoof")
    }

    func testSpeedPresetCyclesThroughAndWraps() {
        XCTAssertEqual(RouteSpeedPreset.nextKilometersPerHour(after: 3), 5)
        XCTAssertEqual(RouteSpeedPreset.nextKilometersPerHour(after: 5), 8)
        XCTAssertEqual(RouteSpeedPreset.nextKilometersPerHour(after: 7), 8)
        XCTAssertEqual(RouteSpeedPreset.nextKilometersPerHour(after: 15), 3)
        XCTAssertEqual(RouteSpeedPreset.compactText(kilometersPerHour: 5), "5km/h")
        XCTAssertEqual(RouteSpeedPreset.compactText(kilometersPerHour: 5.04), "5km/h")
    }

    func testCycleSpeedIsAllowedOnlyWhileWalkingOrUserPaused() {
        let playing = islandContext(routePhase: .playing)
        XCTAssertEqual(IslandCommandRouter.decide("cycleSpeed", context: playing), .run)

        let paused = islandContext(routePhase: .paused, interruption: .userPaused)
        XCTAssertEqual(IslandCommandRouter.decide("cycleSpeed", context: paused), .run)

        let fault = islandContext(routePhase: .paused, interruption: .pushFailed)
        XCTAssertEqual(
            IslandCommandRouter.decide("cycleSpeed", context: fault),
            .unavailable("现在不能调整速度。")
        )
        XCTAssertEqual(
            IslandCommandRouter.decide("cycleSpeed", context: islandContext()),
            .unavailable("现在不能调整速度。")
        )
    }

    func testSwitchFavoriteIsBlockedDuringRoutePlayback() {
        let favoriteAction = IslandFavoriteCommand.action(for: UUID())
        XCTAssertEqual(
            IslandCommandRouter.decide(favoriteAction, context: islandContext(routePhase: .playing)),
            .unavailable("路线还在使用定位，不能另开定点。")
        )
        XCTAssertEqual(
            IslandCommandRouter.decide(favoriteAction, context: islandContext(spoofState: .active)),
            .run
        )
    }

    @MainActor
    func testSwitchFavoriteCommandCanBeQueuedAndInvalidUUIDIsRejected() {
        let suite = "island-favorite-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = RouteActivityCommandStore.defaults
        RouteActivityCommandStore.defaults = defaults
        defer {
            RouteActivityCommandStore.defaults = previous
            defaults.removePersistentDomain(forName: suite)
            RouteActivityBridge.handler = nil
            RouteActivityBridge.expirationHandler = nil
            RouteActivityBridge.inFlightAction = nil
        }
        RouteActivityBridge.handler = nil
        RouteActivityBridge.expirationHandler = nil
        RouteActivityBridge.inFlightAction = nil

        XCTAssertEqual(RouteActivityBridge.submit("switchFavorite:not-a-uuid"), .rejected)
        XCTAssertNil(RouteActivityCommandStore.peek())

        let action = IslandFavoriteCommand.action(for: UUID())
        XCTAssertEqual(RouteActivityBridge.submit(action), .queued)
        XCTAssertEqual(RouteActivityCommandStore.peek(), action)
    }

    func testOldContentStateDecodesMissingTertiaryFields() throws {
        guard #available(iOS 16.2, *) else { return }
        let json = """
        {"kind":"route","title":"步行","statusText":"进行中","detailText":"还剩 800 米 · 10分","distanceText":"800 米","timeText":"10分","progress":0.2,"showsProgress":true,"symbolName":"figure.walk","isWarning":false,"primaryAction":"pause","primaryTitle":"暂停","secondaryAction":"stopRoute","secondaryTitle":"停止路线"}
        """
        let decoded = try JSONDecoder().decode(
            RouteActivityAttributes.ContentState.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.tertiaryAction, "")
        XCTAssertEqual(decoded.tertiaryTitle, "")
        XCTAssertEqual(decoded.speedText, "")
        XCTAssertEqual(decoded.primaryAction, "pause")
    }

    func testPlayingSnapshotUsesCenterSpeedAndNextGear() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .playing,
            statusMessage: "正在走",
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(snapshot?.tertiaryAction, "cycleSpeed")
        XCTAssertEqual(snapshot?.tertiaryTitle, "8km/h")
        XCTAssertEqual(snapshot?.speedText, "5km/h")
        XCTAssertTrue(RouteActivitySync.detailText(for: snapshot!).contains("5km/h"))
        let buttons = RouteIslandActions.buttons(
            phase: "playing",
            primaryAction: snapshot!.primaryAction,
            primaryTitle: snapshot!.primaryTitle,
            secondaryAction: snapshot!.secondaryAction,
            secondaryTitle: snapshot!.secondaryTitle,
            tertiaryAction: snapshot!.tertiaryAction,
            tertiaryTitle: snapshot!.tertiaryTitle,
            isStale: false
        )
        XCTAssertEqual(buttons.tertiaryAction, "cycleSpeed")
        XCTAssertEqual(buttons.tertiaryTitle, "8km/h")
    }

    func testRetryResolvesToRecordedFavoriteCommand() {
        let action = IslandFavoriteCommand.action(for: UUID())
        let context = islandContext(spoofState: .active, retryCommand: action)
        XCTAssertEqual(IslandCommandRouter.resolve("retry", context: context), action)
    }

    private func favorite(_ name: String, lat: Double, lon: Double, id: UUID = UUID()) -> FavoriteLocation {
        FavoriteLocation(
            id: id,
            name: name,
            coordinatePair: CoordinateConverter.coordinatePair(
                lat: lat,
                lon: lon,
                mapCoordinateSystem: .wgs84
            ),
            accuracy: 20
        )
    }

    private func islandContext(
        routePhase: RoutePhase = .inactive,
        interruption: RouteInterruption = .playing,
        spoofState: SpoofState = .idle,
        retryCommand: String = ""
    ) -> IslandCommandContext {
        IslandCommandContext(
            routePhase: routePhase,
            interruption: interruption,
            statusMessage: "",
            waitingForActivation: false,
            spoofState: spoofState,
            needsSwitch: false,
            spotStopPending: false,
            spotSwitchPending: false,
            retryCommand: retryCommand
        )
    }
}
