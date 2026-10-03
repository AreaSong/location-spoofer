import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class MovementLifecycleTests: XCTestCase {
    func testStoppedWalkDrainsOnlyStartedSampleWithoutClearing() async {
        let fixture = Fixture(mode: .thirdParty)
        let walk = makeWalk(fixture)
        let entered = expectation(description: "走动写入已发送")
        fixture.holdNext(entered)
        walk.start(latitude: 1, longitude: 2)
        await walk.ingest(sample: .init(distanceMeters: 0, steps: 0))
        let first = Task { await walk.ingest(sample: .init(distanceMeters: 10, steps: 0)) }
        await fulfillment(of: [entered], timeout: 2)
        await walk.ingest(sample: .init(distanceMeters: 30, steps: 0))
        let drain = walk.stop()
        fixture.release(success: true)
        await drain?.value
        await first.value
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.mapWrites.count, 1)
        assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
        XCTAssertEqual(fixture.clearCount, 0)
        XCTAssertFalse(walk.isTracking)
        XCTAssertEqual(walk.status, .idle)
    }

    func testRestartedWalkIgnoresLateSuccess() async { await checkWalkRestart(success: true) }
    func testRestartedWalkIgnoresLateFailure() async { await checkWalkRestart(success: false) }

    private func checkWalkRestart(success: Bool) async {
        let fixture = Fixture(mode: .thirdParty)
        let walk = makeWalk(fixture)
        let entered = expectation(description: "旧走动已发送")
        fixture.holdNext(entered)
        walk.start(latitude: 1, longitude: 2)
        await walk.ingest(sample: .init(distanceMeters: 0, steps: 0))
        let first = Task { await walk.ingest(sample: .init(distanceMeters: 10, steps: 0)) }
        await fulfillment(of: [entered], timeout: 2)
        walk.stop()
        walk.start(latitude: 3, longitude: 4)
        await walk.ingest(sample: .init(distanceMeters: 0, steps: 0))
        await walk.ingest(sample: .init(distanceMeters: 20, steps: 0))
        XCTAssertEqual(fixture.writes.count, 1)
        fixture.release(success: success)
        await first.value
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertEqual(fixture.mapWrites.count, 1)
        XCTAssertEqual(fixture.failures, 0)
        XCTAssertTrue(walk.isTracking)
        XCTAssertEqual(walk.movedMeters, 20, accuracy: 0.01)
        XCTAssertEqual(fixture.mapWrites.last?.wgs84.latitude ?? 0, walk.currentLatitude ?? 0, accuracy: 1e-8)
        assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
        // 旧成功不能覆盖新门控；紧邻新成功点的小位移应被节流。
        walk.ignoresWriteGate = false
        await walk.ingest(sample: .init(distanceMeters: 21, steps: 0))
        XCTAssertEqual(fixture.writes.count, 2)
        walk.stop()
    }

    func testRouteExitUsesFinalThirdPartyReceipt() async { await checkRouteExit(success: true, initial: true) }
    func testRouteExitKeepsTrustedPointAfterFailure() async { await checkRouteExit(success: false, initial: true) }
    func testRouteExitWithoutSuccessfulPointDoesNotAdopt() async { await checkRouteExit(success: false, initial: false) }

    private func checkRouteExit(success: Bool, initial: Bool) async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        if initial { _ = await fixture.session.writeMoving(pair(1, 2)) }
        let entered = expectation(description: "播放 B 已发送")
        fixture.holdNext(entered)
        fixture.responseOffset = 0.0000001
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)
        let pending = route.exit()
        route.exit()
        XCTAssertTrue(fixture.handoffs.isEmpty)
        fixture.release(success: success)
        await pending?.value
        await route.waitForHandoff()
        XCTAssertEqual(fixture.handoffs.count, initial || success ? 1 : 0)
        assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
        assertCoordinate(fixture.handoffs.last, equals: fixture.device)
        XCTAssertEqual(fixture.clearCount, 0)
        XCTAssertEqual(route.phase, .inactive)
    }

    func testPausedWriteSettlesWithoutHandoffAndCanResume() async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        let entered = expectation(description: "暂停前的写入")
        fixture.holdNext(entered)
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)
        route.pause()
        fixture.release(success: true)
        // 退出提供同一收尾句柄；退出之前暂停不能发出定点接管。
        XCTAssertEqual(route.phase, .paused)
        XCTAssertEqual(route.interruption, .userPaused)
        XCTAssertTrue(fixture.handoffs.isEmpty)
        let resumed = expectation(description: "恢复后的新写入")
        fixture.afterWrite = { resumed.fulfill() }
        route.resume()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(route.phase, .playing)
        await route.exit()?.value
        await route.waitForHandoff()
        XCTAssertEqual(fixture.handoffs.count, 1)
    }

    func testPendingActivationExitAlsoDrainsSessionActivation() async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        let entered = expectation(description: "开启定位的保存")
        fixture.holdNext(entered)
        route.requestPlay()
        route.beginActivation {
            fixture.session.begin(target: self.favorite(1, 2), isRouteActivation: true)
            await fixture.session.waitForOperation()
            return fixture.session.state == .active
        }
        await fulfillment(of: [entered], timeout: 2)
        let pending = route.exit()
        fixture.release(success: true)
        await pending?.value
        await route.waitForHandoff()
        XCTAssertEqual(fixture.handoffs.count, 1)
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertFalse(route.waitingForActivation)
        XCTAssertEqual(route.phase, .inactive)
    }

    func testStoppedWalkDoesNotSubmitSampleWaitingBehindRoute() async {
        await checkStoppedWalkBehindRoute(hasSample: true, success: true)
    }

    func testWalkStoppedBeforeFirstSampleStillSettlesFinalReceipt() async {
        await checkStoppedWalkBehindRoute(hasSample: false, success: true)
    }

    func testStoppedWalkBehindFailedRouteKeepsPreviousSuccess() async {
        await checkStoppedWalkBehindRoute(hasSample: true, success: false)
    }

    private func checkStoppedWalkBehindRoute(hasSample: Bool, success: Bool) async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        _ = await fixture.session.writeMoving(pair(0.5, 2))
        fixture.session.adoptActiveLocation(latitude: 0.5, longitude: 2)
        let entered = expectation(description: "路线 IO 挂起")
        fixture.holdNext(entered)
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)
        let routeDrain = route.exit()
        let walk = makeWalk(fixture)
        walk.start(latitude: 3, longitude: 4)
        await walk.ingest(sample: .init(distanceMeters: 0, steps: 0))
        var sample: Task<Void, Never>?
        if hasSample {
            let queued = expectation(description: "走动进入协调边界")
            let bound = walk.applyCoordinate
            walk.applyCoordinate = { pair in
                queued.fulfill()
                return await bound?(pair) ?? false
            }
            sample = Task { await walk.ingest(sample: .init(distanceMeters: 10, steps: 0)) }
            await fulfillment(of: [queued], timeout: 2)
        }
        let walkDrain = walk.stop()
        fixture.release(success: success)
        await routeDrain?.value
        await walkDrain?.value
        await sample?.value
        await route.waitForHandoff()
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertEqual(fixture.mapWrites.count, 1)
        assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
        assertCoordinate(fixture.mapWrites.last, equals: fixture.device)
        XCTAssertTrue(fixture.handoffs.isEmpty)
        XCTAssertEqual(fixture.session.state, .active)
        XCTAssertFalse(walk.isTracking)
        XCTAssertEqual(fixture.failures, 0)
    }

    func testRepeatedResumeAndPauseOwnOnlyOneDrainWaiter() async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        let entered = expectation(description: "旧设备写入挂起")
        fixture.holdNext(entered)
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)
        route.pause()
        route.resume()
        let waiter = route.producerStartID
        XCTAssertNotNil(waiter)
        for _ in 0..<100 {
            route.pause()
            route.resume()
            XCTAssertEqual(route.producerStartID, waiter)
        }
        XCTAssertEqual(fixture.writes.count, 1)
        let finalWrite = expectation(description: "最后一次恢复的写入")
        fixture.afterWrite = {
            if fixture.writes.count == 2 { finalWrite.fulfill() }
            else { fixture.afterWrite = { finalWrite.fulfill() } }
        }
        fixture.release(success: true)
        await fulfillment(of: [finalWrite], timeout: 2)
        let drain = route.exit()
        await drain?.value
        await route.waitForHandoff()
        XCTAssertNil(route.producerStartID)
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertEqual(fixture.handoffs.count, 1)
    }

    func testForegroundQueryDoesNotDiscardInFlightRouteReceipt() async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        _ = await fixture.session.writeMoving(pair(3, 4))
        let entered = expectation(description: "路线 B 挂起")
        fixture.holdNext(entered)
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)
        fixture.session.refreshThirdParty()
        let pending = route.exit()
        fixture.release(success: true)
        await pending?.value
        await fixture.session.waitForOperation()
        await route.waitForHandoff()
        XCTAssertEqual(fixture.queryCount, 0)
        XCTAssertEqual(fixture.handoffs.count, 1)
        assertCoordinate(fixture.handoffs.last, equals: fixture.device)
        assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
    }

    func testStopSpoofInvalidatesPendingHandoff() async { await checkNewIntent(.stop) }
    func testModeCleanupInvalidatesPendingHandoff() async { await checkNewIntent(.mode) }
    func testNewRouteInvalidatesPendingHandoff() async { await checkNewIntent(.route) }
    func testWalkInvalidatesPendingRouteHandoff() async { await checkNewIntent(.walk) }
    func testExplicitSpotInvalidatesPendingRouteHandoff() async { await checkNewIntent(.spot) }

    private enum Intent { case stop, mode, route, walk, spot }

    private func checkNewIntent(_ intent: Intent) async {
        let fixture = Fixture(mode: .thirdParty)
        let route = makeRoute(fixture)
        let entered = expectation(description: "退出前写入")
        fixture.holdNext(entered)
        route.requestPlay()
        route.noteActivated()
        await fulfillment(of: [entered], timeout: 2)
        let pending = route.exit()
        var walk: PhysicalWalkController?
        switch intent {
        case .stop: fixture.session.stop()
        case .mode:
            fixture.session.beginModeCleanup()
            fixture.probe.mode = .localWiFi
            fixture.session.cancelForModeChange()
            fixture.session.endModeCleanup()
        case .route:
            route.load(savedRoute(3, 4))
            route.requestPlay()
            route.noteActivated()
        case .walk:
            fixture.session.adoptActiveLocation(latitude: 3, longitude: 4)
            walk = makeWalk(fixture)
            walk?.start(latitude: 3, longitude: 4)
        case .spot: fixture.session.begin(target: favorite(3, 4))
        }
        fixture.release(success: true)
        await pending?.value
        await route.waitForHandoff()
        await fixture.session.waitForOperation()
        XCTAssertTrue(fixture.handoffs.isEmpty)
        switch intent {
        case .stop, .mode:
            XCTAssertNil(fixture.session.writtenCoordinate)
            XCTAssertTrue(fixture.session.writesSuspended)
        case .spot:
            XCTAssertEqual(fixture.session.writtenLatitude, 3)
            assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
        case .walk:
            assertCoordinate(fixture.session.writtenCoordinate, equals: fixture.device)
            XCTAssertEqual(walk?.currentLatitude, 3)
            XCTAssertTrue(fixture.mapWrites.isEmpty)
        case .route:
            XCTAssertEqual(route.phase, .playing)
            XCTAssertEqual(route.start?.wgs84.latitude, 3)
        }
        walk?.stop()
        await route.exit()?.value
    }

    func testNaturalCompletionHandsOffOnlyOnceInLocalMode() async {
        let fixture = Fixture(mode: .localWiFi)
        let route = makeRoute(fixture)
        var clock = Date(timeIntervalSince1970: 100)
        route.now = { clock }
        let completed = expectation(description: "自然完成接管")
        fixture.onHandoff = { completed.fulfill() }
        route.requestPlay()
        route.noteActivated()
        clock = clock.addingTimeInterval(10000)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(route.phase, .finished)
        assertCoordinate(fixture.handoffs.last, equals: route.end)
        route.exit()
        route.exit()
        await route.waitForHandoff()
        XCTAssertEqual(fixture.handoffs.count, 1)
        XCTAssertEqual(fixture.clearCount, 0)
    }

    func testRecoveredPauseExitUsesTrustedSessionCoordinateWithoutWriting() async {
        let fixture = Fixture(mode: .localWiFi)
        let route = makeRoute(fixture)
        _ = await fixture.session.writeMoving(pair(1.0004, 2))
        route.applyRecovery(RouteSession(
            routeID: nil, name: "恢复路线", start: pair(1, 2), end: pair(1.001, 2), viaPoints: [],
            travelMode: .walk, speedKilometersPerHour: 5, offsetMeters: 0, repeatMode: .once,
            straightFallback: nil, progress: 0.4, elapsed: 12, headingForward: true,
            interruption: .userPaused, updatedAt: Date()
        ))
        XCTAssertEqual(route.phase, .paused)
        route.exit()
        await route.waitForHandoff()
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertEqual(fixture.handoffs.count, 1)
        assertCoordinate(fixture.handoffs.last, equals: fixture.device)
    }

    private func makeWalk(_ fixture: Fixture) -> PhysicalWalkController {
        let walk = PhysicalWalkController(sensor: LifecyclePedometer(), heading: LifecycleHeading())
        walk.ignoresWriteGate = true
        fixture.session.bindPhysicalWalk(walk) { fixture.mapWrites.append($0) }
        addTeardownBlock { await MainActor.run { walk.stop(); walk.stopHeading() } }
        return walk
    }

    private func makeRoute(_ fixture: Fixture) -> RoutePlaybackController {
        let suite = "MovementLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let route = RoutePlaybackController(
            preferenceStore: .init(defaults: defaults), sessionStore: .init(defaults: defaults)
        )
        route.load(savedRoute(1, 2))
        route.ignoresWriteGate = true
        route.tickIntervalNanoseconds = 60_000_000_000
        fixture.session.bindRoutePlayback(route) { pair in
            fixture.handoffs.append(pair)
            fixture.onHandoff?()
        }
        addTeardownBlock {
            await route.exit()?.value
            defaults.removePersistentDomain(forName: suite)
        }
        return route
    }

    private func savedRoute(_ lat: Double, _ lon: Double) -> SavedRoute {
        SavedRoute(name: "合成路线", start: pair(lat, lon), end: pair(lat + 0.001, lon),
                   travelMode: .walk, speedKilometersPerHour: 5, offsetMeters: 0,
                   repeatMode: .once, pathPoints: [pair(lat, lon), pair(lat + 0.001, lon)])
    }

    private func pair(_ lat: Double, _ lon: Double) -> CoordinatePair {
        CoordinateConverter.coordinatePair(lat: lat, lon: lon, mapCoordinateSystem: .wgs84)
    }

    private func favorite(_ lat: Double, _ lon: Double) -> FavoriteLocation {
        FavoriteLocation(name: "合成点", coordinatePair: pair(lat, lon), accuracy: 20)
    }

    private func assertCoordinate(_ actual: CoordinatePair?, equals expected: CoordinatePair?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual?.wgs84.latitude, expected?.wgs84.latitude, file: file, line: line)
        XCTAssertEqual(actual?.wgs84.longitude, expected?.wgs84.longitude, file: file, line: line)
    }
}

@MainActor
private final class Fixture {
    let session = SpoofSession()
    let probe = SpoofServiceProbe()
    var writes: [CoordinatePair] = []
    var mapWrites: [CoordinatePair] = []
    var handoffs: [CoordinatePair] = []
    var device: CoordinatePair?
    var failures = 0
    var clearCount = 0
    var queryCount = 0
    var responseOffset = 0.0
    var afterWrite: (() -> Void)?
    var onHandoff: (() -> Void)?
    private var entered: XCTestExpectation?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(mode: ProxyRuntimeMode) {
        probe.mode = mode
        var services = probe.services()
        services.saveThirdParty = { favorite, _ in
            let success = await self.write(favorite.coordinatePair)
            guard success else { throw URLError(.cannotConnectToHost) }
            let coordinate = self.device!.wgs84
            return .init(success: true, longitude: coordinate.longitude, latitude: coordinate.latitude,
                         accuracy: 20, error: nil, motionSimulationEnabled: nil)
        }
        services.updateLocalWGS84 = { lat, lon, _ in
            let pair = CoordinateConverter.coordinatePair(lat: lat, lon: lon, mapCoordinateSystem: .wgs84)
            self.writes.append(pair)
            self.device = pair
            return true
        }
        services.queryThirdParty = {
            self.queryCount += 1
            return self.probe.saveResponse
        }
        services.clearThirdParty = { self.clearCount += 1; self.device = nil }
        services.clearLocal = { self.clearCount += 1; self.device = nil }
        services.recordThirdPartyFailure = { _ in self.failures += 1 }
        session.bind(services)
    }

    func holdNext(_ entered: XCTestExpectation) { self.entered = entered }
    func release(success: Bool) { continuation?.resume(returning: success); continuation = nil }

    private func write(_ pair: CoordinatePair) async -> Bool {
        writes.append(pair)
        let success: Bool
        if let entered {
            self.entered = nil
            success = await withCheckedContinuation { continuation = $0; entered.fulfill() }
        } else { success = true }
        if success {
            device = CoordinateConverter.coordinatePair(
                lat: pair.wgs84.latitude + responseOffset, lon: pair.wgs84.longitude, mapCoordinateSystem: .wgs84
            )
        }
        let after = afterWrite
        afterWrite = nil
        after?()
        return success
    }
}

@MainActor
private final class LifecyclePedometer: PhysicalWalkSensing {
    var isStepCountingAvailable = true
    func authorizationStatus() -> PhysicalWalkAuthorization { .allowed }
    func requestAuthorization(_ completion: @escaping (PhysicalWalkAuthorization) -> Void) { completion(.allowed) }
    func start(from date: Date, handler: @escaping (PhysicalWalkSample?, Error?) -> Void) {}
    func stop() {}
}

@MainActor
private final class LifecycleHeading: PhysicalWalkHeadingSensing {
    var headingAvailable = true
    var latestYawDegrees: Double? = 0
    var latestMapHeadingDegrees: Double? = 0
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
}
