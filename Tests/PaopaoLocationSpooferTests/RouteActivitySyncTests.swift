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
        XCTAssertEqual(snapshot?.phaseKey, .userPaused)
        XCTAssertEqual(snapshot?.statusText, "已暂停")
        XCTAssertEqual(snapshot?.symbolName, "pause.fill")
        XCTAssertEqual(snapshot?.primaryAction, "resume")
        XCTAssertEqual(snapshot?.primaryTitle, "继续")
        XCTAssertEqual(snapshot?.secondaryAction, "stopRoute")
        XCTAssertEqual(snapshot?.secondaryTitle, "停止路线")
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
        XCTAssertEqual(snapshot?.phaseKey, .systemFault)
        XCTAssertEqual(snapshot?.statusText, "异常")
        XCTAssertEqual(snapshot?.retryCommand, "resume")
        XCTAssertEqual(snapshot?.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(snapshot?.primaryAction, "retry")
        XCTAssertEqual(snapshot?.primaryTitle, "重试")
        XCTAssertEqual(snapshot?.secondaryAction, "openApp")
        XCTAssertNotEqual(snapshot?.primaryTitle, "继续")
    }

    func testSameMinuteDoesNotPushAgain() {
        let first = playingSnapshot(remainingMeters: 900)
        var later = first
        later.progress += 0.009
        XCTAssertFalse(RouteActivitySync.shouldUpdate(first, to: later))
    }

    func testProgressOrDetailChangePushes() {
        let first = playingSnapshot(remainingMeters: 900)
        let detailChanged = playingSnapshot(remainingMeters: 860)
        XCTAssertNotEqual(first.distanceText, detailChanged.distanceText)
        XCTAssertTrue(RouteActivitySync.shouldUpdate(first, to: detailChanged))

        var progressChanged = first
        progressChanged.progress += RouteActivitySync.minimumProgressDelta
        XCTAssertTrue(RouteActivitySync.shouldUpdate(first, to: progressChanged))
    }

    @MainActor
    func testIslandCommandWaitsUntilHandlersExist() {
        let suite = "route-activity-command-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = RouteActivityCommandStore.defaults
        RouteActivityCommandStore.defaults = defaults
        defer {
            RouteActivityCommandStore.defaults = previous
            defaults.removePersistentDomain(forName: suite)
            RouteActivityBridge.handler = nil
        }

        RouteActivityBridge.handler = nil
        var ran = false
        RouteActivityBridge.submit("pause")
        XCTAssertFalse(ran)

        RouteActivityBridge.handler = { action in
            ran = action == "pause"
        }
        RouteActivityBridge.drainPending()
        XCTAssertTrue(ran)
        XCTAssertNil(RouteActivityCommandStore.consume())
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

    func testSpotIslandUsesStatusWithoutCoordinates() {
        let locating = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: true,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25
        )
        XCTAssertEqual(locating?.statusText, "定位中")
        XCTAssertEqual(locating?.symbolName, "location.fill")
        XCTAssertEqual(locating?.primaryAction, "stopSpoof")
        XCTAssertEqual(locating?.primaryTitle, "停止虚拟定位")
        XCTAssertEqual(locating?.caption, "GCJ-02 · 精度 25 米")

        let moved = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: true,
            needsSwitch: true,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25
        )
        XCTAssertEqual(moved?.statusText, "待切换")
        XCTAssertEqual(moved?.primaryTitle, "切换到此处")
        XCTAssertEqual(moved?.secondaryAction, "stopSpoof")

        let verifying = SpotActivitySync.snapshot(
            isVerifying: true,
            isActive: false,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "WGS-84",
            accuracyMeters: 10
        )
        XCTAssertEqual(verifying?.statusText, "验证中")
        XCTAssertEqual(verifying?.primaryAction, "")

        let failed = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: false,
            needsSwitch: false,
            failed: true,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25
        )
        XCTAssertEqual(failed?.status, .notApplied)
        XCTAssertEqual(failed?.statusText, "未生效")
        XCTAssertEqual(failed?.retryCommand, "begin")
        XCTAssertEqual(failed?.isWarning, true)
        XCTAssertEqual(failed?.primaryTitle, "重试")
        XCTAssertEqual(failed?.secondaryTitle, "打开 App")
        XCTAssertNil(SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: false,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25
        ))
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

    func testStaleDateFollowsPhase() {
        let now = Date(timeIntervalSince1970: 1_000)
        let playing = playingSnapshot(remainingMeters: 900)
        let paused = RouteActivitySync.snapshot(
            phase: .paused,
            statusMessage: RouteActivitySync.userPauseMessage,
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )!
        let failed = RouteActivitySync.snapshot(
            phase: .paused,
            statusMessage: "系统定位推送失败，已暂停。",
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )!
        XCTAssertEqual(RouteActivitySync.staleDate(for: playing, now: now), now.addingTimeInterval(45))
        XCTAssertNil(RouteActivitySync.staleDate(for: paused, now: now))
        XCTAssertEqual(RouteActivitySync.staleDate(for: failed, now: now), now.addingTimeInterval(120))
    }

    func testActivationFailureStaysOnTheIsland() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .preparing,
            interruption: .activationFailed,
            statusMessage: "系统定位推送失败，已暂停。",
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(snapshot?.phaseKey, .systemFault)
        XCTAssertEqual(snapshot?.primaryTitle, "重试")
        XCTAssertEqual(snapshot?.secondaryTitle, "打开 App")
        XCTAssertEqual(snapshot?.retryCommand, "play")
        XCTAssertNotEqual(snapshot?.primaryTitle, "继续")
    }

    func testPlainPreparingStillHidesTheActivity() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .preparing,
            interruption: .playing,
            statusMessage: "先设起点",
            routeName: "步行路线",
            remainingMeters: 0,
            speedMetersPerSecond: 1.4,
            progress: 0,
            symbolName: "figure.walk"
        )
        XCTAssertNil(snapshot)
    }

    func testStoppedRouteConfirmsWithoutButtons() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .preparing,
            interruption: .playing,
            statusMessage: RouteActivitySync.stoppedMessage,
            routeName: "步行路线",
            remainingMeters: 400,
            speedMetersPerSecond: 1.4,
            progress: 0.4,
            symbolName: "figure.walk",
            confirmStopped: true
        )
        XCTAssertEqual(snapshot?.phaseKey, .stopped)
        XCTAssertEqual(snapshot?.statusText, "已停止")
        XCTAssertEqual(snapshot?.primaryAction, "")
        XCTAssertNil(RouteActivitySync.staleDate(for: snapshot!, now: Date(timeIntervalSince1970: 1_000)))
    }

    func testActionChangePushes() {
        var first = playingSnapshot(remainingMeters: 900)
        var next = first
        next.primaryAction = "resume"
        XCTAssertTrue(RouteActivitySync.shouldUpdate(first, to: next))
        first.isWarning = false
        next = first
        next.isWarning = true
        XCTAssertTrue(RouteActivitySync.shouldUpdate(first, to: next))
    }

    func testSpotStoppingAndActionFailure() {
        let stopping = SpotActivitySync.snapshot(
            isVerifying: true,
            isActive: false,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            isStopping: true
        )
        XCTAssertEqual(stopping?.status, .stopping)
        XCTAssertEqual(stopping?.statusText, "正在停止")
        XCTAssertEqual(stopping?.primaryAction, "")

        let failedAction = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: true,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            actionFailed: true,
            errorText: "推送失败",
            retryCommand: "stopSpoof"
        )
        XCTAssertEqual(failedAction?.status, .actionFailed)
        XCTAssertEqual(failedAction?.primaryTitle, "重试")
        XCTAssertEqual(failedAction?.retryCommand, "stopSpoof")
        XCTAssertNotEqual(failedAction?.statusText, "验证中")
    }

    func testLocationBlockMessageIsNotUserPause() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .paused,
            interruption: .pushFailed,
            statusMessage: RouteActivitySync.locationBlockedMessage,
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(snapshot?.phaseKey, .systemFault)
        XCTAssertEqual(snapshot?.primaryAction, "retry")
        XCTAssertNotEqual(snapshot?.primaryTitle, "继续")
    }

    func testRouteSnapshotDropsSpotActions() {
        var snapshot = playingSnapshot(remainingMeters: 900)
        snapshot.primaryAction = "stopSpoof"
        snapshot.primaryTitle = "停止虚拟定位"
        snapshot.secondaryAction = "pause"
        snapshot.secondaryTitle = "暂停"
        let normalized = RouteActivitySync.normalized(snapshot)
        XCTAssertEqual(normalized.primaryAction, "pause")
        XCTAssertEqual(normalized.secondaryAction, "")
        XCTAssertNotEqual(normalized.primaryAction, "stopSpoof")
    }

    func testSpotSnapshotDropsRouteActions() {
        let locating = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: true,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25
        )!
        var edited = locating
        edited.primaryAction = "pause"
        edited.primaryTitle = "暂停"
        edited.secondaryAction = "stopRoute"
        edited.secondaryTitle = "停止路线"
        let normalized = SpotActivitySync.normalized(edited)
        XCTAssertEqual(normalized.primaryAction, "")
        XCTAssertEqual(normalized.secondaryAction, "")
    }

    func testConflictingPauseAndResumeKeepsOneButton() {
        var snapshot = playingSnapshot(remainingMeters: 900)
        snapshot.phaseKey = .userPaused
        snapshot.primaryAction = "resume"
        snapshot.primaryTitle = "继续"
        snapshot.secondaryAction = "pause"
        snapshot.secondaryTitle = "暂停"
        let normalized = RouteActivitySync.normalized(snapshot)
        XCTAssertEqual(normalized.primaryAction, "resume")
        XCTAssertEqual(normalized.secondaryAction, "")
    }

    func testRetryingHasNoButtons() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .paused,
            interruption: .pushFailed,
            statusMessage: "系统定位推送失败，已暂停。",
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk",
            isRetrying: true
        )
        XCTAssertEqual(snapshot?.phaseKey, .retrying)
        XCTAssertEqual(snapshot?.statusText, "重试中")
        XCTAssertEqual(snapshot?.primaryAction, "")
        XCTAssertEqual(snapshot?.secondaryAction, "")
        XCTAssertEqual(snapshot?.timeText, "10分")
    }

    func testCommandFailureKeepsTheFailedCommand() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .playing,
            statusMessage: "暂停没有执行。",
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "figure.walk",
            commandFailed: true,
            failedCommand: "pause"
        )
        XCTAssertEqual(snapshot?.phaseKey, .actionFailed)
        XCTAssertEqual(snapshot?.primaryAction, "retry")
        XCTAssertEqual(snapshot?.secondaryAction, "openApp")
        XCTAssertEqual(snapshot?.retryCommand, "pause")
        XCTAssertNotEqual(snapshot?.primaryTitle, "继续")
    }

    func testSpotSwitchingAndStoppedHaveNoButtons() {
        let switching = SpotActivitySync.snapshot(
            isVerifying: true,
            isActive: false,
            needsSwitch: true,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            isSwitching: true
        )
        XCTAssertEqual(switching?.status, .switching)
        XCTAssertEqual(switching?.statusText, "切换中")
        XCTAssertEqual(switching?.primaryAction, "")

        let stopped = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: false,
            needsSwitch: false,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            isStopped: true
        )
        XCTAssertEqual(stopped?.status, .stopped)
        XCTAssertEqual(stopped?.statusText, "已停止")
        XCTAssertEqual(stopped?.primaryAction, "")
        XCTAssertNil(SpotActivitySync.staleDate(for: stopped!, now: Date(timeIntervalSince1970: 1_000)))
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
