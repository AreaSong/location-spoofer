import XCTest
@testable import PaopaoLocationSpoofer

final class RouteActivitySyncTests: XCTestCase {
    func testUserPauseIsNotAWarning() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .paused,
            statusMessage: RouteActivitySync.userPauseMessage,
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(snapshot?.phaseKey, .paused)
        XCTAssertEqual(snapshot?.isWarning, false)
        XCTAssertEqual(snapshot?.canToggle, true)
    }

    func testPushFailurePauseIsAWarning() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .paused,
            statusMessage: "系统定位推送失败，已暂停。",
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(snapshot?.phaseKey, .warning)
        XCTAssertEqual(snapshot?.statusText, "系统定位推送失败，已暂停。")
        XCTAssertEqual(snapshot?.canToggle, false)
    }

    func testSameMinuteDoesNotPushAgain() {
        let first = playingSnapshot(remainingMeters: 900)
        let later = playingSnapshot(remainingMeters: 860)
        XCTAssertFalse(RouteActivitySync.shouldUpdate(first, to: later))
    }

    func testMinuteChangePushes() {
        let first = playingSnapshot(remainingMeters: 900)
        let later = playingSnapshot(remainingMeters: 200)
        XCTAssertTrue(RouteActivitySync.shouldUpdate(first, to: later))
    }

    func testPreparingHidesTheActivity() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .preparing,
            statusMessage: "先设起点",
            routeName: "步行路线",
            remainingMeters: 0,
            speedMetersPerSecond: 1.4,
            progress: 0,
            symbolName: "figure.walk"
        )
        XCTAssertNil(snapshot)
    }

    func testChangingSpeedKeepsProgress() {
        let start = CoordinateConverter.coordinatePair(lat: 22.494, lon: 113.951, mapCoordinateSystem: .wgs84)
        let end = CoordinateConverter.coordinatePair(lat: 22.504, lon: 113.951, mapCoordinateSystem: .wgs84)
        let path = RoutePath.make([start, end])
        let progress = 0.35
        let slowElapsed = RoutePlayback.elapsed(
            progress: progress,
            totalMeters: path.totalMeters,
            speedMetersPerSecond: 1.4
        )
        let fastElapsed = RoutePlayback.elapsed(
            progress: progress,
            totalMeters: path.totalMeters,
            speedMetersPerSecond: 5.6
        )
        let slow = RoutePlayback.tick(path: path, speedMetersPerSecond: 1.4, elapsed: slowElapsed)
        let fast = RoutePlayback.tick(path: path, speedMetersPerSecond: 5.6, elapsed: fastElapsed)
        XCTAssertEqual(slow.progress, progress, accuracy: 0.02)
        XCTAssertEqual(fast.progress, progress, accuracy: 0.02)
    }

    private func playingSnapshot(remainingMeters: Double) -> RouteActivitySnapshot {
        RouteActivitySync.snapshot(
            phase: .playing,
            statusMessage: "正在走",
            routeName: "步行路线",
            remainingMeters: remainingMeters,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )!
    }
}
