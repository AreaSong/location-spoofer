import CoreLocation
import CoreMotion
import MapKit
import SwiftUI
import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class PhysicalWalkDirectionTests: XCTestCase {
    func testWaitingAndResolvedHeadingRenderInBothThemes() {
        let suite = "DirectionRendering.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhysicalWalkStore(defaults: defaults)
        store.setEnabled(true)
        let heading = DirectionHeading()
        let walk = PhysicalWalkController(sensor: DirectionPedometer(), heading: heading)
        for dark in [false, true] {
            for degrees: Double? in [nil, 45] {
                heading.latestMapHeadingDegrees = degrees
                walk.startHeadingPreview()
                let content = PhysicalWalkHeadingControls(store: store, controller: walk, spoofActive: true)
                    .padding(16).frame(width: 375, height: 300)
                    .background(dark ? Color.black : Color.white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = UIHostingController(rootView: content)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 300))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "heading-\(dark ? "dark" : "light")-\(degrees == nil ? "waiting" : "valid")"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
            }
        }
        walk.stopHeading()
    }

    func testAbsoluteDirectionsAndCoordinatePairsThroughDeveloperWrites() async throws {
        // 独立预期：单位北/东分量，不调用生产 offset 函数计算期望坐标。
        let directions: [(Double, Double, Double)] = [
            (0, 1, 0), (90, 0, 1), (180, -1, 0), (270, 0, -1),
            (45, 0.7071067812, 0.7071067812),
            (359, 0.9998476952, -0.0174524064), (1, 0.9998476952, 0.0174524064)
        ]
        for origin in [(22.494, 113.951), (37.7749, -122.4194)] {
            for (degrees, north, east) in directions {
                let fixture = DirectionFixture(latitude: origin.0, longitude: origin.1)
                fixture.heading.latestYawDegrees = 123 // 与绝对航向故意不一致。
                fixture.heading.latestMapHeadingDegrees = degrees
                fixture.start()
                await fixture.walk.ingest(sample: .init(steps: 0))
                for step in 1...100 {
                    await fixture.walk.ingest(sample: .init(distanceMeters: 0, steps: step))
                    if step == 10 || step == 100 {
                        let written = try XCTUnwrap(fixture.writes.last)
                        assertDisplacement(written, from: origin, north: north * Double(step), east: east * Double(step))
                        XCTAssertEqual(fixture.walk.activeHeadingDegrees, degrees)
                        XCTAssertEqual(fixture.session.writtenCoordinate, written)
                        XCTAssertEqual(fixture.mapWrites.last, written)
                        for system: CoordinateConverter.MapCoordinateSystem in [.wgs84, .gcj02] {
                            let puck = WalkPuckMapPlacement.coordinate(
                                spoofActive: true, writtenLatitude: written.wgs84.latitude,
                                writtenLongitude: written.wgs84.longitude,
                                liveLatitude: fixture.walk.currentLatitude, liveLongitude: fixture.walk.currentLongitude,
                                realtimeCoordinate: .init(latitude: -30, longitude: -60), mapSystem: system
                            )
                            XCTAssertEqual(puck?.latitude, written.coordinate(for: system).latitude)
                            XCTAssertEqual(puck?.longitude, written.coordinate(for: system).longitude)
                        }
                    }
                }
                XCTAssertEqual(fixture.walk.movedMeters, 100)
                XCTAssertEqual(fixture.spotOffsetCalls, 0)
                await fixture.stop()
                XCTAssertEqual(fixture.session.writtenCoordinate, fixture.writes.last)
                XCTAssertEqual(fixture.probe.developerClears, 0)
            }
        }
    }

    func testTurnTimingAndWraparoundAffectOnlyFollowingSteps() async throws {
        let fixture = DirectionFixture()
        fixture.heading.latestMapHeadingDegrees = 359
        fixture.start()
        await fixture.walk.ingest(sample: .init(steps: 0))
        for (index, degrees) in [359.0, 0, 1, 90].enumerated() {
            let previous = fixture.writes.last?.wgs84 ?? .init(latitude: 0, longitude: 0)
            fixture.heading.latestMapHeadingDegrees = degrees
            fixture.heading.onChange?()
            XCTAssertEqual(fixture.writes.count, index, "单独转动不能补写已有步伐")
            await fixture.walk.ingest(sample: .init(steps: index + 1))
            let pair = try XCTUnwrap(fixture.writes.last)
            let expected: [(Double, Double)] = [(0.9998476952, -0.0174524064), (1, 0), (0.9998476952, 0.0174524064), (0, 1)]
            assertDisplacement(pair, from: (previous.latitude, previous.longitude), north: expected[index].0, east: expected[index].1)
        }
        fixture.heading.latestMapHeadingDegrees = 180
        fixture.heading.onChange?()
        XCTAssertEqual(fixture.writes.count, 4)
        await fixture.stop()
    }

    func testSuspendedDeveloperWriteCoalescesFinalHundredStepsWithoutRotating() async throws {
        let fixture = DirectionFixture()
        let entered = expectation(description: "开发者写入挂起")
        var release: CheckedContinuation<Void, Never>?
        fixture.beforePush = { if fixture.writes.count == 1 {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        } }
        fixture.heading.latestMapHeadingDegrees = 45
        fixture.start()
        await fixture.walk.ingest(sample: .init(steps: 0))
        let first = Task { await fixture.walk.ingest(sample: .init(steps: 1)) }
        await fulfillment(of: [entered], timeout: 2)
        for step in 2...100 { await fixture.walk.ingest(sample: .init(steps: step)) }
        XCTAssertEqual(fixture.writes.count, 1)
        release?.resume()
        await first.value
        XCTAssertEqual(fixture.writes.count, 2)
        let last = try XCTUnwrap(fixture.writes.last)
        assertDisplacement(last, from: (0, 0), north: 70.71067812, east: 70.71067812)
        XCTAssertEqual(fixture.session.writtenCoordinate, last)
        await fixture.stop()
    }

    func testModeSwitchesAndRestartDoNotLeakCustomZeroIntoCompassMode() async throws {
        let fixture = DirectionFixture()
        fixture.heading.latestMapHeadingDegrees = 90
        fixture.heading.latestYawDegrees = 10
        fixture.walk.applyPersistedInitial(180)
        fixture.start()
        await fixture.walk.ingest(sample: .init(steps: 0))
        fixture.walk.setCustomHeadingEnabled(true)
        fixture.heading.latestYawDegrees = 100
        fixture.heading.onChange?()
        XCTAssertEqual(fixture.walk.activeHeadingDegrees, 270)
        fixture.walk.setCustomHeadingEnabled(false)
        XCTAssertEqual(fixture.walk.activeHeadingDegrees, 90)
        await fixture.walk.ingest(sample: .init(steps: 1))
        assertDisplacement(try XCTUnwrap(fixture.writes.last), from: (0, 0), north: 0, east: 1)
        await fixture.stop()
        fixture.walk.start(latitude: fixture.session.writtenLatitude!, longitude: fixture.session.writtenLongitude!)
        await fixture.walk.ingest(sample: .init(steps: 0))
        await fixture.walk.ingest(sample: .init(steps: 1))
        assertDisplacement(try XCTUnwrap(fixture.writes.last), from: (0, 0), north: 0, east: 2)
        fixture.walk.setCustomHeadingEnabled(true)
        XCTAssertEqual(fixture.walk.activeHeadingDegrees, 180, "重新开启时以当前姿态重新取零点")
        await fixture.stop()
    }

    func testDefaultFrameUsesTrueNorthInsteadOfMagneticNorth() {
        XCTAssertEqual(PhysicalWalkHeadingDriver.attitudeReferenceFrame(
            availableFrames: [.xMagneticNorthZVertical, .xTrueNorthZVertical]
        ), .xTrueNorthZVertical)
    }

    func testMissingAbsoluteHeadingDoesNotMoveAlongArbitraryYaw() async {
        let heading = DirectionHeading()
        heading.latestYawDegrees = 45
        let walk = PhysicalWalkController(sensor: DirectionPedometer(), heading: heading)
        var writes = 0
        walk.applyCoordinate = { _ in writes += 1; return true }
        walk.start(latitude: 0, longitude: 0)
        await walk.ingest(sample: .init(steps: 0))
        await walk.ingest(sample: .init(steps: 1))
        XCTAssertNil(walk.activeHeadingDegrees)
        XCTAssertEqual(walk.status, .waitingForHeading)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(walk.movedMeters, 0)
        heading.latestMapHeadingDegrees = 90
        heading.onChange?()
        XCTAssertEqual(writes, 0, "恢复朝向不能把未知方向的旧步数补到新方向")
        await walk.ingest(sample: .init(steps: 2))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(walk.movedMeters, 0.74)
        walk.stop()
        walk.stopHeading()
    }

    func testRotatedMapFanMatchesProjectedStep() async throws {
        let heading = DirectionHeading()
        heading.latestMapHeadingDegrees = 0
        let walk = PhysicalWalkController(sensor: DirectionPedometer(), heading: heading)
        walk.ignoresWriteGate = true
        walk.strideMeters = { 1 }
        var written: CoordinatePair?
        walk.applyCoordinate = { written = $0; return true }
        walk.start(latitude: 0, longitude: 0)
        await walk.ingest(sample: .init(steps: 0))
        await walk.ingest(sample: .init(steps: 10))
        let pair = try XCTUnwrap(written)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        map.camera = MKMapCamera(lookingAtCenter: .init(latitude: 0, longitude: 0),
                                 fromDistance: 500, pitch: 0, heading: 315)
        let parent = makeMap(heading: walk.activeHeadingDegrees)
        let coordinator = parent.makeCoordinator()
        coordinator.installWalkHeadingHud(on: map)
        coordinator.updateWalkHeadingHud(degrees: walk.activeHeadingDegrees, visible: true, on: map)
        let hud = try XCTUnwrap(coordinator.walkHeadingHud)
        // 地理北向在这张地图中是画面右上；不能仍画成屏幕正上方。
        XCTAssertEqual(hud.headingDegrees, 45, accuracy: 0.01)
        XCTAssertEqual(pair.wgs84.longitude, 0, accuracy: 1e-10)
        XCTAssertGreaterThan(pair.wgs84.latitude, 0)
        let origin = map.convert(.init(latitude: 0, longitude: 0), toPointTo: map)
        let end = map.convert(pair.wgs84.coordinate, toPointTo: map)
        XCTAssertGreaterThan(end.x, origin.x)
        XCTAssertLessThan(end.y, origin.y)
        for rotation in [0.0, 90, 180, 315] {
            for pitch in [0.0, 45] {
                map.camera = MKMapCamera(lookingAtCenter: .init(latitude: 0, longitude: 0),
                                         fromDistance: 500, pitch: pitch, heading: rotation)
                coordinator.positionWalkHeadingHud(on: map)
                let start = map.convert(.init(latitude: 0, longitude: 0), toPointTo: map)
                let end = map.convert(pair.wgs84.coordinate, toPointTo: map)
                let angle = hud.headingDegrees * .pi / 180
                let length = hypot(end.x - start.x, end.y - start.y)
                XCTAssertEqual(sin(angle), (end.x - start.x) / length, accuracy: 0.001)
                XCTAssertEqual(-cos(angle), (end.y - start.y) / length, accuracy: 0.001)
                XCTAssertEqual(hud.accessibilityValue, "北 0°")
                XCTAssertEqual(walk.currentLongitude, 0, "地图姿态不能反馈到地理位移")
            }
        }
        coordinator.updateWalkHeadingHud(degrees: nil, visible: true, on: map)
        XCTAssertEqual(hud.accessibilityValue, "等待朝向")
        XCTAssertTrue(hud.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first?.isHidden ?? false)
        XCTAssertEqual(PhysicalWalkHeadingLock.labeledDegrees(nil), "等待朝向")
        coordinator.stopWalkPuckTracking()
        walk.stop()
        walk.stopHeading()
    }

    private func makeMap(heading: Double?) -> MapViewRepresentable {
        MapViewRepresentable(
            selection: .init(coordinate: .init(latitude: 0, longitude: 0), source: .mapTap, explicitName: nil, revision: 0),
            initialViewportMeters: 500, cameraCommand: nil,
            onRealtimeLocationChanged: { _ in }, onUserCenterChanged: { _, _ in },
            onViewportChanged: { _ in }, onMapTap: { _ in }, onUserZoomChanged: nil,
            walkHeadingDegrees: heading, walkPuckCoordinate: .init(latitude: 0, longitude: 0),
            showsWalkHeading: true
        )
    }

    private func assertDisplacement(_ pair: CoordinatePair, from origin: (Double, Double), north: Double, east: Double,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let metersPerDegree = 111_194.92664455874
        XCTAssertEqual((pair.wgs84.latitude - origin.0) * metersPerDegree, north, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual((pair.wgs84.longitude - origin.1) * metersPerDegree * cos(origin.0 * .pi / 180), east,
                       accuracy: 0.002, file: file, line: line)
    }
}

@MainActor
private final class DirectionFixture {
    let probe = SpoofServiceProbe()
    let session: SpoofSession
    let heading = DirectionHeading()
    let walk: PhysicalWalkController
    var writes: [CoordinatePair] = []
    var mapWrites: [CoordinatePair] = []
    var spotOffsetCalls = 0
    var beforePush: (() async -> Void)?

    init(latitude: Double = 0, longitude: Double = 0) {
        session = SpoofSession(state: .active, writtenLatitude: latitude, writtenLongitude: longitude)
        walk = PhysicalWalkController(sensor: DirectionPedometer(), heading: heading)
        probe.mode = .developerTunnel
        var services = probe.services()
        services.routeOffsetMeters = { 100 }
        services.developerSpotWGS84 = { lat, lon in
            self.spotOffsetCalls += 1
            return (lat + 1, lon + 1)
        }
        services.pushDeveloper = { favorite in
            self.writes.append(favorite.coordinatePair)
            await self.beforePush?()
            return nil
        }
        session.bind(services)
        session.bindPhysicalWalk(walk) { self.mapWrites.append($0) }
        walk.ignoresWriteGate = true
        walk.strideMeters = { 1 }
    }

    func start() { walk.start(latitude: session.writtenLatitude!, longitude: session.writtenLongitude!) }
    func stop() async { await walk.stop()?.value; walk.stopHeading() }
}

@MainActor
private final class DirectionHeading: PhysicalWalkHeadingSensing {
    var headingAvailable = true
    var latestYawDegrees: Double?
    var latestMapHeadingDegrees: Double?
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class DirectionPedometer: PhysicalWalkSensing {
    var isStepCountingAvailable = true
    func authorizationStatus() -> PhysicalWalkAuthorization { .allowed }
    func requestAuthorization(_ completion: @escaping (PhysicalWalkAuthorization) -> Void) { completion(.allowed) }
    func start(from date: Date, handler: @escaping (PhysicalWalkSample?, Error?) -> Void) {}
    func stop() {}
}

@MainActor
final class MapCenterPinTests: XCTestCase {
    func testRouteProgressKeepsCenterSelectionPinVisible() {
        let parent = MapViewRepresentable(
            selection: .init(
                coordinate: .init(latitude: 22.5, longitude: 113.9),
                source: .mapTap,
                explicitName: nil,
                revision: 0
            ),
            initialViewportMeters: 500,
            cameraCommand: nil,
            onRealtimeLocationChanged: { _ in },
            onUserCenterChanged: { _, _ in },
            onViewportChanged: { _ in },
            onMapTap: { _ in },
            onUserZoomChanged: nil
        )
        let coordinator = parent.makeCoordinator()
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let pin = UIImageView()
        pin.isHidden = true
        coordinator.centerPin = pin
        coordinator.updateRouteProgress(.init(latitude: 22.54, longitude: 113.94), on: map)
        XCTAssertFalse(pin.isHidden, "playback marker must not hide the map-center selection pin")
        coordinator.updateRouteProgress(nil, on: map)
        XCTAssertFalse(pin.isHidden)
    }
}
