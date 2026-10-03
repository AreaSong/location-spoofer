import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ProxyAccuracyTests: XCTestCase {
    func testBridgeRejectsInvalidValuesBeforeWriteOrRevisionChange() throws {
        let suite = "ProxyAccuracy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var writes: [CInt] = []
        let proxy = ProxyManager(loadSettings: { nil }, motionSimulation: MotionSimulationStore(defaults: defaults)) {
            _, _, _, accuracy, _ in writes.append(accuracy)
        }
        for accuracy in [Int.min, Int(Int32.min), -1, 0, 4, 101, Int(Int32.max), Int(Int32.max) + 1, Int.max] {
            XCTAssertThrowsError(try proxy.setCoords(lat: 1, lon: 2, enabled: true, accuracy: accuracy)) {
                XCTAssertEqual($0 as? LocationAccuracy.ValidationError, .outOfRange(accuracy))
            }
            XCTAssertThrowsError(try proxy.setCoordsIfUnchanged(
                lat: 1, lon: 2, enabled: true, accuracy: accuracy, expectedRevision: 0
            ))
            let snapshot = ProxyCoordinateSnapshot(latitude: 1, longitude: 2, enabled: true, accuracy: accuracy, revision: 0)
            XCTAssertThrowsError(try proxy.restoreCoords(snapshot, ifUnchangedSince: 0))
        }
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try proxy.setCoordsIfUnchanged(lat: 1, lon: 2, enabled: true, accuracy: 27, expectedRevision: 0), 1)
        XCTAssertEqual(writes, [27])
        XCTAssertNil(try proxy.setCoordsIfUnchanged(lat: 3, lon: 4, enabled: true, accuracy: 25, expectedRevision: 0))
        let snapshot = ProxyCoordinateSnapshot(latitude: 1, longitude: 2, enabled: true, accuracy: 100, revision: 1)
        XCTAssertTrue(try proxy.restoreCoords(snapshot, ifUnchangedSince: 1))
        XCTAssertEqual(writes, [27, 100])
    }

    func testOldPersistedBadAccuracyRejectsStartupAndMotionWithoutMutation() async throws {
        let suite = "ProxyAccuracyRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let motion = MotionSimulationStore(defaults: defaults)
        var writes = 0
        let proxy = ProxyManager(loadSettings: {
            defaults.data(forKey: WlocKeys.coords).flatMap { try? JSONDecoder().decode(WlocSettings.self, from: $0) }
        }, motionSimulation: motion) { _, _, _, _, _ in writes += 1 }
        for enabled in [false, true] {
            for accuracy in [Int(Int32.max) + 1, Int.max, -1, 0, 101] {
                let bytes = try JSONEncoder().encode(WlocSettings(longitude: 1, latitude: 2, accuracy: accuracy, enabled: enabled))
                defaults.set(bytes, forKey: WlocKeys.coords)
                do {
                    try await proxy.start()
                    XCTFail("旧异常精度必须在启动前拒绝")
                } catch {
                    XCTAssertEqual(error as? LocationAccuracy.ValidationError, .outOfRange(accuracy))
                }
                XCTAssertThrowsError(try proxy.applyMotionSimulation(true))
                XCTAssertFalse(proxy.isRunning)
                XCTAssertFalse(motion.isEnabled)
                XCTAssertEqual(defaults.data(forKey: WlocKeys.coords), bytes)
                XCTAssertEqual(writes, 0)
            }
        }
    }
}
