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
        XCTAssertEqual(snapshot?.errorText, "系统定位推送失败，已暂停。")
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
        let meterChanged = playingSnapshot(remainingMeters: 899)
        XCTAssertNotEqual(first.distanceText, meterChanged.distanceText)
        XCTAssertEqual(first.timeText, meterChanged.timeText)
        XCTAssertFalse(RouteActivitySync.shouldUpdate(first, to: meterChanged))

        let sameMinute = playingSnapshot(remainingMeters: 860)
        XCTAssertNotEqual(first.distanceText, sameMinute.distanceText)
        XCTAssertEqual(first.timeText, sameMinute.timeText)
        XCTAssertFalse(RouteActivitySync.shouldUpdate(first, to: sameMinute))

        var progressChanged = first
        progressChanged.progress += RouteActivitySync.minimumProgressDelta
        progressChanged.distanceText = sameMinute.distanceText
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
            RouteActivityBridge.expirationHandler = nil
            RouteActivityBridge.inFlightAction = nil
        }

        RouteActivityBridge.handler = nil
        RouteActivityBridge.expirationHandler = nil
        RouteActivityBridge.inFlightAction = nil
        var ran = false
        XCTAssertEqual(RouteActivityBridge.submit("pause"), .queued)
        XCTAssertFalse(ran)

        RouteActivityBridge.handler = { action in
            ran = action == "pause"
        }
        RouteActivityBridge.drainPending()
        XCTAssertTrue(ran)
        XCTAssertNil(RouteActivityCommandStore.consume())
    }

    func testExpiredIslandCommandIsDropped() {
        let suite = "route-activity-expiry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previousDefaults = RouteActivityCommandStore.defaults
        let previousNow = RouteActivityCommandStore.now
        RouteActivityCommandStore.defaults = defaults
        defer {
            RouteActivityCommandStore.defaults = previousDefaults
            RouteActivityCommandStore.now = previousNow
            defaults.removePersistentDomain(forName: suite)
        }

        let issued = Date(timeIntervalSince1970: 1_000)
        RouteActivityCommandStore.now = { issued }
        RouteActivityCommandStore.enqueue("resume")
        RouteActivityCommandStore.now = { issued.addingTimeInterval(RouteActivityCommandStore.maxAge + 1) }
        XCTAssertNil(RouteActivityCommandStore.consume())
        XCTAssertEqual(RouteActivityCommandStore.takeExpiredAction(), "resume")

        defaults.set("resume", forKey: RouteActivityCommandStore.pendingKey)
        XCTAssertNil(RouteActivityCommandStore.consume())
        XCTAssertEqual(RouteActivityCommandStore.takeExpiredAction(), "resume")
    }

    func testNewerIslandCommandReplacesTheQueuedOne() {
        let suite = "route-activity-replace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = RouteActivityCommandStore.defaults
        RouteActivityCommandStore.defaults = defaults
        defer {
            RouteActivityCommandStore.defaults = previous
            defaults.removePersistentDomain(forName: suite)
        }

        RouteActivityCommandStore.enqueue("pause")
        RouteActivityCommandStore.enqueue("stopRoute")
        XCTAssertEqual(RouteActivityCommandStore.peek(), "stopRoute")
        XCTAssertEqual(RouteActivityCommandStore.consume(), "stopRoute")
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

    func testFinishedUsesCheckmark() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .finished,
            statusMessage: "",
            routeName: "步行路线",
            remainingMeters: 0,
            speedMetersPerSecond: 1.4,
            progress: 1,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(snapshot?.phaseKey, .finished)
        XCTAssertEqual(snapshot?.symbolName, "checkmark")
        XCTAssertEqual(snapshot?.statusText, "已完成")
        XCTAssertEqual(snapshot?.progress, 1)
        XCTAssertEqual(snapshot?.primaryAction, "")
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
        XCTAssertEqual(RouteActivitySync.detailText(for: snapshot!), RouteActivitySync.keptLocationDetail)
        XCTAssertEqual(snapshot?.errorText, "")
        XCTAssertNil(RouteActivitySync.staleDate(for: snapshot!, now: Date(timeIntervalSince1970: 1_000)))
    }

    func testStoppedRouteHandsOffToSpotAfterConfirm() {
        let now = Date(timeIntervalSince1970: 1_000)
        let until = now.addingTimeInterval(RouteActivitySync.stoppedConfirmInterval)
        XCTAssertFalse(RouteActivitySync.suppressStoppedRoute(confirmUntil: until, now: now, spotStillActive: true))
        XCTAssertTrue(RouteActivitySync.suppressStoppedRoute(confirmUntil: until, now: until, spotStillActive: true))
        XCTAssertFalse(RouteActivitySync.suppressStoppedRoute(confirmUntil: until, now: until, spotStillActive: false))
        XCTAssertFalse(RouteActivitySync.suppressStoppedRoute(confirmUntil: nil, now: until, spotStillActive: true))
    }

    func testStaleIslandDropsPauseAndKeepsRetry() {
        let playing = IslandActionPresentation.buttons(
            phase: "playing",
            primaryAction: "pause",
            primaryTitle: "暂停",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            isStale: true
        )
        XCTAssertEqual(playing.primaryAction, "retry")
        XCTAssertEqual(playing.primaryTitle, "重试")
        XCTAssertEqual(playing.secondaryAction, "openApp")
        XCTAssertEqual(
            IslandActionPresentation.submittedAction(action: playing.primaryAction, phase: "playing", retryCommand: ""),
            "play"
        )

        let locating = IslandActionPresentation.buttons(
            phase: "locating",
            primaryAction: "stopSpoof",
            primaryTitle: "停止虚拟定位",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(locating.primaryAction, "retry")
        XCTAssertEqual(locating.secondaryAction, "openApp")
        XCTAssertEqual(
            IslandActionPresentation.submittedAction(action: locating.primaryAction, phase: "locating", retryCommand: ""),
            "begin"
        )

        let fault = IslandActionPresentation.buttons(
            phase: "systemFault",
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            isStale: true
        )
        XCTAssertEqual(fault.primaryAction, "retry")
        XCTAssertEqual(fault.secondaryAction, "openApp")

        let paused = IslandActionPresentation.buttons(
            phase: "userPaused",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            isStale: true
        )
        XCTAssertEqual(paused.primaryAction, "resume")
        XCTAssertEqual(paused.primaryTitle, "继续")
        XCTAssertEqual(paused.secondaryAction, "openApp")
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

    func testSpotIslandActionsFollowStatus() {
        let needsSwitch = SpotIslandActions.buttons(
            phase: "needsSwitch",
            primaryAction: "switchHere",
            primaryTitle: "切换到此处",
            secondaryAction: "stopSpoof",
            secondaryTitle: "停止虚拟定位",
            isStale: false
        )
        XCTAssertEqual(needsSwitch.primaryAction, "switchHere")
        XCTAssertEqual(needsSwitch.primaryTitle, "切换到此处")
        XCTAssertEqual(needsSwitch.secondaryAction, "stopSpoof")
        XCTAssertEqual(needsSwitch.secondaryTitle, "停止虚拟定位")

        let locating = SpotIslandActions.buttons(
            phase: "locating",
            primaryAction: "switchHere",
            primaryTitle: "切换到此处",
            secondaryAction: "stopSpoof",
            secondaryTitle: "停止虚拟定位",
            isStale: false
        )
        XCTAssertEqual(locating.primaryAction, "stopSpoof")
        XCTAssertEqual(locating.primaryTitle, "停止虚拟定位")
        XCTAssertEqual(locating.secondaryAction, "")

        let switching = SpotIslandActions.buttons(
            phase: "switching",
            primaryAction: "switchHere",
            primaryTitle: "切换到此处",
            secondaryAction: "stopSpoof",
            secondaryTitle: "停止虚拟定位",
            isStale: false
        )
        XCTAssertEqual(switching.primaryAction, "")
        XCTAssertEqual(switching.secondaryAction, "")

        let staleSwitching = SpotIslandActions.buttons(
            phase: "switching",
            primaryAction: "switchHere",
            primaryTitle: "切换到此处",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(staleSwitching.primaryAction, "openApp")
        XCTAssertEqual(staleSwitching.secondaryAction, "")

        let stopped = SpotIslandActions.buttons(
            phase: "stopped",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "switchHere",
            secondaryTitle: "切换到此处",
            isStale: false
        )
        XCTAssertEqual(stopped.primaryAction, "")
        XCTAssertEqual(stopped.secondaryAction, "")

        let notApplied = SpotIslandActions.buttons(
            phase: "notApplied",
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            isStale: false
        )
        XCTAssertEqual(notApplied.primaryAction, "retry")
        XCTAssertEqual(notApplied.secondaryAction, "openApp")

        let failed = SpotIslandActions.buttons(
            phase: "actionFailed",
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            isStale: false
        )
        XCTAssertEqual(failed.primaryAction, "retry")
        XCTAssertEqual(failed.secondaryTitle, "打开 App")
        XCTAssertEqual(
            IslandActionPresentation.submittedAction(action: failed.primaryAction, phase: "actionFailed", retryCommand: "stopSpoof"),
            "stopSpoof"
        )
    }

    func testSpotFailureAndStoppedDisplay() {
        let failed = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: true,
            needsSwitch: false,
            failed: false,
            placeName: "非常长的地点名称不应该把状态挤出灵动岛",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            actionFailed: true,
            errorText: "推送失败",
            retryCommand: "begin"
        )
        XCTAssertEqual(failed?.status, .actionFailed)
        XCTAssertEqual(failed?.statusText, "操作失败")
        XCTAssertEqual(failed?.errorText, "推送失败")
        XCTAssertEqual(failed?.caption, "GCJ-02 · 精度 25 米")
        XCTAssertFalse(failed?.caption.contains("暂停") == true)

        let stopped = SpotActivitySync.snapshot(
            isVerifying: false,
            isActive: false,
            needsSwitch: true,
            failed: false,
            placeName: "深圳湾",
            coordinateStandard: "GCJ-02",
            accuracyMeters: 25,
            isStopped: true
        )
        XCTAssertEqual(stopped?.status, .stopped)
        XCTAssertEqual(stopped?.primaryAction, "")
        XCTAssertEqual(stopped?.secondaryAction, "")
        XCTAssertNotEqual(stopped?.primaryTitle, "继续")
        XCTAssertNotEqual(stopped?.primaryTitle, "切换到此处")
    }

    func testRouteRetryStaysVisibleUntilActivationSettles() {
        let waiting = RouteCommandTracking.afterAttempt(
            command: "play",
            phase: .preparing,
            interruption: .playing,
            waitingForActivation: true,
            statusMessage: "正在开启虚拟定位…"
        )
        XCTAssertTrue(waiting.isRetrying)
        XCTAssertFalse(waiting.commandFailed)

        let settled = waiting.reconcile(phase: .playing, interruption: .playing, waitingForActivation: false)
        XCTAssertFalse(settled.isRetrying)

        let blocked = RouteCommandTracking.afterAttempt(
            command: "resume",
            phase: .paused,
            interruption: .pushFailed,
            waitingForActivation: false,
            statusMessage: RouteActivitySync.locationBlockedMessage
        )
        XCTAssertFalse(blocked.isRetrying)
        XCTAssertFalse(blocked.commandFailed)
    }

    func testRouteCommandFailureKeepsTheAttemptedCommand() {
        let paused = RouteCommandTracking.afterAttempt(
            command: "pause",
            phase: .playing,
            interruption: .playing,
            waitingForActivation: false,
            statusMessage: "正在走"
        )
        XCTAssertTrue(paused.commandFailed)
        XCTAssertEqual(paused.failedCommand, "pause")

        let stopped = RouteCommandTracking.afterAttempt(
            command: "stopRoute",
            phase: .preparing,
            interruption: .playing,
            waitingForActivation: false,
            statusMessage: RouteActivitySync.stoppedMessage
        )
        XCTAssertFalse(stopped.commandFailed)

        let playing = paused.reconcile(phase: .playing, interruption: .playing, waitingForActivation: false)
        XCTAssertFalse(playing.commandFailed)
    }

    func testPlanningShowsRouteWithoutPlaybackButtons() {
        let named = RouteActivitySync.snapshot(
            phase: .preparing,
            statusMessage: RouteActivitySync.planningMessage,
            routeName: "很长的滨海步行路线名称不应该撑破布局",
            remainingMeters: 0,
            speedMetersPerSecond: 1.4,
            progress: 0,
            symbolName: "figure.walk"
        )
        XCTAssertEqual(named?.phaseKey, .planning)
        XCTAssertEqual(named?.statusText, "规划中")
        XCTAssertEqual(named?.modeSymbolName, "figure.walk")
        XCTAssertEqual(named?.primaryAction, "")
        XCTAssertEqual(named?.secondaryAction, "")
        XCTAssertEqual(RouteActivitySync.detailText(for: named!), "正在规划路线")
        XCTAssertNotEqual(named?.primaryTitle, "继续")
        XCTAssertNotEqual(named?.secondaryTitle, "停止虚拟定位")

        let flagged = RouteActivitySync.snapshot(
            phase: .preparing,
            statusMessage: "先设起点",
            routeName: "骑行路线",
            remainingMeters: 1_200,
            speedMetersPerSecond: 4,
            progress: 0,
            symbolName: "bicycle",
            isPlanning: true
        )
        XCTAssertEqual(flagged?.phaseKey, .planning)
        XCTAssertEqual(flagged?.modeSymbolName, "bicycle")
        XCTAssertFalse(flagged?.distanceText.isEmpty == true)
        XCTAssertFalse(flagged?.timeText.isEmpty == true)
    }

    func testFinishedAndStoppedDoNotOfferResume() {
        let finished = RouteActivitySync.snapshot(
            phase: .finished,
            statusMessage: "",
            routeName: "步行路线",
            remainingMeters: 0,
            speedMetersPerSecond: 1.4,
            progress: 1,
            symbolName: "figure.walk"
        )!
        XCTAssertEqual(finished.primaryAction, "")
        XCTAssertEqual(finished.secondaryAction, "")
        XCTAssertEqual(RouteActivitySync.detailText(for: finished), "已走完")
        XCTAssertEqual(finished.modeSymbolName, "figure.walk")

        let stopped = RouteActivitySync.snapshot(
            phase: .preparing,
            statusMessage: RouteActivitySync.stoppedMessage,
            routeName: "步行路线",
            remainingMeters: 0,
            speedMetersPerSecond: 1.4,
            progress: 0.4,
            symbolName: "bicycle",
            confirmStopped: true
        )!
        XCTAssertEqual(stopped.phaseKey, .stopped)
        XCTAssertEqual(stopped.primaryTitle, "")
        XCTAssertEqual(stopped.secondaryTitle, "")
        XCTAssertEqual(stopped.modeSymbolName, "bicycle")
        XCTAssertNotEqual(stopped.secondaryAction, "stopSpoof")
    }

    func testUserPauseKeepsTravelIconAndStopRoute() {
        let snapshot = RouteActivitySync.snapshot(
            phase: .paused,
            statusMessage: RouteActivitySync.userPauseMessage,
            routeName: "步行路线",
            remainingMeters: 800,
            speedMetersPerSecond: 1.4,
            progress: 0.2,
            symbolName: "bicycle"
        )
        XCTAssertEqual(snapshot?.symbolName, "pause.fill")
        XCTAssertEqual(snapshot?.modeSymbolName, "bicycle")
        XCTAssertEqual(snapshot?.primaryAction, "resume")
        XCTAssertEqual(snapshot?.secondaryAction, "stopRoute")
        XCTAssertEqual(snapshot?.secondaryTitle, "停止路线")
    }

    func testRouteIslandActionsMatchRouteStates() {
        let playing = RouteIslandActions.buttons(
            phase: "playing",
            primaryAction: "pause",
            primaryTitle: "暂停",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            isStale: false
        )
        XCTAssertEqual(playing.primaryAction, "pause")
        XCTAssertEqual(playing.secondaryAction, "stopRoute")
        XCTAssertEqual(playing.secondaryTitle, "停止路线")

        let paused = RouteIslandActions.buttons(
            phase: "userPaused",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            isStale: false
        )
        XCTAssertEqual(paused.primaryAction, "resume")
        XCTAssertEqual(paused.primaryTitle, "继续")
        XCTAssertEqual(paused.secondaryAction, "stopRoute")
        XCTAssertEqual(paused.secondaryTitle, "停止路线")

        let spoof = RouteIslandActions.buttons(
            phase: "userPaused",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopSpoof",
            secondaryTitle: "停止虚拟定位",
            isStale: false
        )
        XCTAssertEqual(spoof.secondaryAction, "")

        let fault = RouteIslandActions.buttons(
            phase: "systemFault",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            isStale: false
        )
        XCTAssertEqual(fault.primaryAction, "openApp")
        XCTAssertNotEqual(fault.primaryAction, "resume")
        XCTAssertNotEqual(fault.secondaryAction, "stopSpoof")

        let retrying = RouteIslandActions.buttons(
            phase: "retrying",
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "openApp",
            secondaryTitle: "打开 App",
            isStale: true
        )
        XCTAssertEqual(retrying.primaryAction, "retry")
        XCTAssertEqual(retrying.secondaryAction, "openApp")

        let stalePlanning = RouteIslandActions.buttons(
            phase: "planning",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(stalePlanning.primaryAction, "openApp")
        XCTAssertEqual(stalePlanning.secondaryAction, "")

        let failed = RouteIslandActions.buttons(
            phase: "actionFailed",
            primaryAction: "retry",
            primaryTitle: "重试",
            secondaryAction: "switchHere",
            secondaryTitle: "切换到此处",
            isStale: false
        )
        XCTAssertEqual(failed.primaryAction, "retry")
        XCTAssertEqual(failed.secondaryAction, "")
    }

    func testRouteCompactFallsBackWhenTimeIsMissing() {
        XCTAssertEqual(
            RouteIslandLayout.compactTrailing(timeText: "12分", statusText: "进行中", isStale: false),
            "12分"
        )
        XCTAssertEqual(
            RouteIslandLayout.compactTrailing(timeText: "", statusText: "已完成", isStale: false),
            "已完成"
        )
        XCTAssertEqual(
            RouteIslandLayout.compactTrailing(timeText: "12分", statusText: "进行中", isStale: true),
            "已中断"
        )
        XCTAssertEqual(
            RouteIslandLayout.compactSymbol(modeSymbolName: "bicycle", symbolName: "pause.fill", isStale: false),
            "bicycle"
        )
        XCTAssertEqual(
            RouteIslandLayout.metricText(
                phase: "finished",
                detailText: "",
                distanceText: "",
                timeText: "",
                statusText: "已完成"
            ),
            "已走完"
        )
        XCTAssertEqual(
            RouteIslandLayout.metricText(
                phase: "playing",
                detailText: "",
                distanceText: "800 米",
                timeText: "10分",
                statusText: "进行中"
            ),
            "还剩 800 米 · 10分"
        )
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
