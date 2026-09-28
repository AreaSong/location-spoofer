import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class SpoofSessionTests: XCTestCase {
    func testSecondBeginWhileVerifyingIsIgnored() async {
        let probe = SpoofServiceProbe()
        let started = expectation(description: "验证开始")
        let gate = PauseGate()
        probe.verifyImpl = {
            await gate.pause(started: started)
            return .success
        }
        let session = makeSession(probe)
        session.begin(target: sampleFavorite())
        await fulfillment(of: [started], timeout: 2)

        session.begin(target: sampleFavorite())

        XCTAssertEqual(probe.verifyCount, 1)
        XCTAssertEqual(session.state, .verifying)
        gate.resume()
        await waitUntil(session, leaves: .verifying)
        XCTAssertEqual(probe.applyCount, 1)
        XCTAssertEqual(probe.updateCount, 0)
        XCTAssertEqual(session.writtenLatitude ?? 0, 22.504, accuracy: 0.000_001)
        XCTAssertEqual(session.writtenLongitude ?? 0, 113.931, accuracy: 0.000_001)
        XCTAssertEqual(session.switchLatitude ?? 0, 22.494, accuracy: 0.000_001)
        XCTAssertEqual(session.switchLongitude ?? 0, 113.951, accuracy: 0.000_001)
    }

    func testSelectionChangeDiscardsAppVerification() async {
        let probe = SpoofServiceProbe()
        probe.verifyImpl = {
            probe.revision = 99
            return .success
        }
        let session = makeSession(probe)

        session.begin(target: sampleFavorite())
        await waitUntil(session, leaves: .verifying)

        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.writtenLatitude)
        XCTAssertNil(session.writtenLongitude)
    }

    func testThirdPartySaveFailureKeepsPreviousCoordinate() async {
        let probe = SpoofServiceProbe()
        probe.mode = .thirdParty
        probe.saveError = ThirdPartyProxyError.rejected("保存失败")
        let session = SpoofSession(state: .active, writtenLatitude: 22.1, writtenLongitude: 113.2)
        session.bind(probe.services())

        session.begin(target: sampleFavorite())
        await waitUntil(session, leaves: .verifying)

        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.writtenLatitude, 22.1)
        XCTAssertEqual(session.writtenLongitude, 113.2)
    }

    func testThirdPartySaveStaysAppliedWhenSelectionMoves() async {
        let probe = SpoofServiceProbe()
        probe.mode = .thirdParty
        probe.saveResponse = response(latitude: 22.5, longitude: 113.9)
        probe.saveImpl = {
            probe.revision = 40
        }
        let session = makeSession(probe)

        session.begin(target: sampleFavorite())
        await waitUntil(session, leaves: .verifying)

        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.writtenLatitude, 22.5)
        XCTAssertEqual(session.writtenLongitude, 113.9)
        XCTAssertEqual(session.switchLatitude ?? 0, 22.494, accuracy: 0.000_001)
        XCTAssertEqual(session.switchLongitude ?? 0, 113.951, accuracy: 0.000_001)
        XCTAssertFalse(
            SpoofSelectionSwitch.needsSwitch(
                isActive: true,
                writtenLatitude: session.switchLatitude,
                writtenLongitude: session.switchLongitude,
                selection: sampleFavorite().coordinatePair
            )
        )
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testDeveloperTunnelPushActivatesAndClearStops() async {
        let probe = SpoofServiceProbe()
        probe.mode = .developerTunnel
        let session = makeSession(probe)

        session.begin(target: sampleFavorite())
        await waitUntil(session, leaves: .verifying)

        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(probe.developerPushes, 1)
        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertEqual(probe.verifyCount, 0)

        session.stop()
        await waitUntil(session, leaves: .verifying)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(probe.developerClears, 1)
        XCTAssertNil(session.writtenLatitude)
    }

    func testDeveloperTunnelSpotOffsetMovesWrittenPointAndKeepsSwitchOnOriginal() async {
        let probe = SpoofServiceProbe()
        probe.mode = .developerTunnel
        probe.developerSpotWGS84 = { latitude, longitude in
            (latitude + 0.01, longitude - 0.02)
        }
        let session = makeSession(probe)
        let target = sampleFavorite()

        session.begin(target: target)
        await waitUntil(session, leaves: .verifying)

        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(probe.lastUpdateLatitude ?? 0, target.latitude + 0.01, accuracy: 0.000_000_1)
        XCTAssertEqual(probe.lastUpdateLongitude ?? 0, target.longitude - 0.02, accuracy: 0.000_000_1)
        XCTAssertEqual(session.writtenLatitude ?? 0, target.latitude + 0.01, accuracy: 0.000_000_1)
        XCTAssertEqual(session.switchLatitude ?? 0, target.latitude, accuracy: 0.000_000_1)
        XCTAssertEqual(session.switchLongitude ?? 0, target.longitude, accuracy: 0.000_000_1)
    }

    func testDeveloperTunnelClearFailureStaysActive() async {
        let probe = SpoofServiceProbe()
        probe.mode = .developerTunnel
        let session = makeSession(probe)
        session.begin(target: sampleFavorite())
        await waitUntil(session, leaves: .verifying)
        session.consumeEffects()
        probe.developerClearFailure = .clearFailed

        session.stop()
        await waitUntil(session, leaves: .verifying)

        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(probe.developerClears, 1)
        XCTAssertEqual(
            session.consumeEffects(),
            [.developerPushFailed(RouteLocationPushFailure.clearFailed.message)]
        )
    }

    func testAdoptActiveLocationDoesNotPushOrClear() {
        let probe = SpoofServiceProbe()
        probe.mode = .developerTunnel
        let session = makeSession(probe)

        session.adoptActiveLocation(latitude: 22.5, longitude: 113.9)

        XCTAssertEqual(session.state, .active)
        XCTAssertEqual(session.writtenLatitude, 22.5)
        XCTAssertEqual(session.writtenLongitude, 113.9)
        XCTAssertEqual(session.switchLatitude, 22.5)
        XCTAssertEqual(session.switchLongitude, 113.9)
        XCTAssertEqual(probe.developerPushes, 0)
        XCTAssertEqual(probe.developerClears, 0)
        XCTAssertEqual(probe.clearLocalCount, 0)
        XCTAssertEqual(probe.updateCount, 0)
        XCTAssertEqual(probe.verifyCount, 0)
        XCTAssertTrue(session.consumeEffects().isEmpty)
    }

    func testNoteExternalClearIdlesWithoutCallingClear() {
        let probe = SpoofServiceProbe()
        probe.mode = .developerTunnel
        let session = makeSession(probe)
        session.adoptActiveLocation(latitude: 22.5, longitude: 113.9)

        session.noteExternalClear()

        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.writtenLatitude)
        XCTAssertEqual(probe.developerClears, 0)
        XCTAssertEqual(probe.pauseRouteCount, 1)
        XCTAssertTrue(session.consumeEffects().isEmpty)
    }

    func testRouteWriteUsesTheSameCoordinateEntry() async {
        let probe = SpoofServiceProbe()
        let session = makeSession(probe)
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )

        let applied = await session.writeRoute(pair, offsetMeters: 0)

        XCTAssertTrue(applied)
        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertEqual(probe.updateCount, 1)
        XCTAssertEqual(session.writtenLatitude ?? 0, pair.wgs84.latitude, accuracy: 0.000_001)
        XCTAssertEqual(session.writtenLongitude ?? 0, pair.wgs84.longitude, accuracy: 0.000_001)

        probe.mode = .thirdParty
        probe.saveResponse = response(latitude: 22.2, longitude: 113.4)
        let routed = await session.writeRoute(pair, offsetMeters: 12)

        XCTAssertTrue(routed)
        XCTAssertEqual(probe.savedRadius, 12)
        XCTAssertEqual(session.writtenLatitude, 22.2)
        XCTAssertEqual(session.writtenLongitude, 113.4)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testWriteMovingUsesExactCoordinatesWithoutRouteOffset() async {
        let probe = SpoofServiceProbe()
        let session = makeSession(probe)
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.494,
            lon: 113.951,
            mapCoordinateSystem: .wgs84
        )

        let applied = await session.writeMoving(pair)

        XCTAssertTrue(applied)
        XCTAssertEqual(probe.updateCount, 1)
        XCTAssertEqual(probe.lastUpdateLatitude ?? 0, pair.wgs84.latitude, accuracy: 0.000_001)
        XCTAssertEqual(probe.lastUpdateLongitude ?? 0, pair.wgs84.longitude, accuracy: 0.000_001)
        XCTAssertEqual(session.writtenLatitude ?? 0, pair.wgs84.latitude, accuracy: 0.000_001)
        XCTAssertEqual(session.writtenLongitude ?? 0, pair.wgs84.longitude, accuracy: 0.000_001)
        XCTAssertEqual(session.switchLatitude ?? 0, pair.wgs84.latitude, accuracy: 0.000_001)
        XCTAssertEqual(session.switchLongitude ?? 0, pair.wgs84.longitude, accuracy: 0.000_001)

        probe.mode = .thirdParty
        probe.saveResponse = response(latitude: 22.2, longitude: 113.4)
        let thirdParty = await session.writeMoving(pair)
        XCTAssertTrue(thirdParty)
        XCTAssertEqual(probe.savedRadius, 0)
        XCTAssertEqual(session.writtenLatitude, 22.2)
        XCTAssertEqual(session.writtenLongitude, 113.4)

        probe.mode = .developerTunnel
        let tunnel = await session.writeMoving(pair)
        XCTAssertTrue(tunnel)
        XCTAssertEqual(probe.developerPushes, 1)
        XCTAssertEqual(probe.lastUpdateLatitude ?? 0, pair.wgs84.latitude, accuracy: 0.000_001)
        XCTAssertEqual(probe.updateCount, 1)
    }

    private func makeSession(_ probe: SpoofServiceProbe) -> SpoofSession {
        let session = SpoofSession()
        session.bind(probe.services())
        return session
    }

    private func sampleFavorite() -> FavoriteLocation {
        FavoriteLocation(
            name: "测试点",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .wgs84
        )
    }

    private func response(latitude: Double, longitude: Double) -> ThirdPartyProxySettingsResponse {
        ThirdPartyProxySettingsResponse(
            success: true,
            longitude: longitude,
            latitude: latitude,
            accuracy: 25,
            error: nil,
            motionSimulationEnabled: nil
        )
    }

    private func waitUntil(_ session: SpoofSession, leaves state: SpoofState) async {
        for _ in 0..<50 {
            if session.state != state { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("状态停留在验证中")
    }
}

@MainActor
private final class PauseGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func pause(started: XCTestExpectation) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class SpoofServiceProbe {
    var mode = ProxyRuntimeMode.localWiFi
    var revision: UInt64 = 1
    var verifyCount = 0
    var applyCount = 0
    var updateCount = 0
    var lastUpdateLatitude: Double?
    var lastUpdateLongitude: Double?
    var savedRadius: Double?
    var saveError: Error?
    var saveResponse = ThirdPartyProxySettingsResponse(
        success: true,
        longitude: 113.9,
        latitude: 22.5,
        accuracy: 25,
        error: nil,
        motionSimulationEnabled: nil
    )
    var verifyImpl: (() async -> VerificationResult)?
    var saveImpl: (() -> Void)?
    var developerPushes = 0
    var developerClears = 0
    var clearLocalCount = 0
    var pauseRouteCount = 0
    var developerFailure: RouteLocationPushFailure?
    var developerClearFailure: RouteLocationPushFailure?
    var developerSpotWGS84: (Double, Double) -> (latitude: Double, longitude: Double) = { ($0, $1) }

    func services() -> SpoofSession.Services {
        SpoofSession.Services(
            mode: { self.mode },
            isUseBlocked: { false },
            selectionRevision: { self.revision },
            localSpoofEnabled: { false },
            thirdPartyClientName: { "测试客户端" },
            routeIsPlaying: { false },
            routeWaitsForActivation: { false },
            routeOffsetMeters: { 0 },
            accuracyMeters: { 25 },
            pauseRoute: { self.pauseRouteCount += 1 },
            verify: {
                self.verifyCount += 1
                if let verifyImpl = self.verifyImpl {
                    return await verifyImpl()
                }
                return .success
            },
            applyVerified: { favorite in
                self.applyCount += 1
                return (favorite.latitude + 0.01, favorite.longitude - 0.02)
            },
            updateLocalWGS84: { latitude, longitude, _ in
                self.updateCount += 1
                self.lastUpdateLatitude = latitude
                self.lastUpdateLongitude = longitude
                return true
            },
            clearLocal: { self.clearLocalCount += 1 },
            saveThirdParty: { _, randomRadius in
                self.savedRadius = randomRadius
                self.saveImpl?()
                if let saveError = self.saveError {
                    throw saveError
                }
                return self.saveResponse
            },
            clearThirdParty: {},
            queryThirdParty: {
                self.saveResponse
            },
            clearThirdPartyFailure: {},
            recordThirdPartyFailure: { _ in },
            recordThirdPartyMessage: { _ in },
            developerSpotWGS84: { latitude, longitude in
                self.developerSpotWGS84(latitude, longitude)
            },
            pushDeveloper: { favorite in
                self.developerPushes += 1
                self.lastUpdateLatitude = favorite.latitude
                self.lastUpdateLongitude = favorite.longitude
                return self.developerFailure
            },
            clearDeveloper: {
                self.developerClears += 1
                return self.developerClearFailure
            }
        )
    }
}
