import XCTest
@testable import PaopaoLocationSpoofer

final class IslandActivityReliabilityTests: XCTestCase {
    func testRouteAndSpotCommandsStayDistinct() {
        let playing = islandContext(routePhase: .playing)
        XCTAssertEqual(IslandCommandRouter.decide("pause", context: playing), .run)
        XCTAssertEqual(IslandCommandRouter.decide("stopRoute", context: playing), .run)
        XCTAssertEqual(
            IslandCommandRouter.decide("stopSpoof", context: playing),
            .unavailable("路线仍在使用定位。停止路线不会关闭定位。")
        )
        XCTAssertEqual(
            IslandCommandRouter.decide("switchHere", context: playing),
            .unavailable("路线还在使用定位，不能另开定点。")
        )
        XCTAssertEqual(IslandCommandRouter.decide("resume", context: playing), .alreadySatisfied)
    }

    func testRepeatedRouteCommandsDoNotStartAnotherPlayback() {
        let paused = islandContext(routePhase: .paused, interruption: .userPaused)
        XCTAssertEqual(IslandCommandRouter.decide("pause", context: paused), .alreadySatisfied)
        XCTAssertEqual(IslandCommandRouter.decide("resume", context: paused), .run)
        XCTAssertEqual(IslandCommandRouter.decide("play", context: paused), .run)

        let waiting = islandContext(routePhase: .preparing, waitingForActivation: true)
        XCTAssertEqual(IslandCommandRouter.decide("play", context: waiting), .alreadySatisfied)
        XCTAssertEqual(IslandCommandRouter.decide("resume", context: waiting), .alreadySatisfied)

        let stopped = islandContext(
            routePhase: .preparing,
            statusMessage: RouteActivitySync.stoppedMessage
        )
        XCTAssertEqual(IslandCommandRouter.decide("stopRoute", context: stopped), .alreadySatisfied)
        XCTAssertNotEqual(IslandCommandRouter.decide("stopRoute", context: stopped), .run)
    }

    func testSystemFaultPauseIsNotTreatedAsUserPause() {
        let fault = islandContext(routePhase: .paused, interruption: .pushFailed)
        XCTAssertEqual(IslandCommandRouter.decide("pause", context: fault), .leaveCurrent)
        XCTAssertEqual(IslandCommandRouter.decide("resume", context: fault), .run)
        XCTAssertEqual(IslandCommandRouter.decide("stopRoute", context: fault), .run)
    }

    func testSpotRetrySwitchAndStopAreIdempotent() {
        let locating = islandContext(spoofState: .active)
        XCTAssertEqual(IslandCommandRouter.decide("stopSpoof", context: locating), .run)
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: locating), .alreadySatisfied)
        XCTAssertEqual(IslandCommandRouter.decide("switchHere", context: locating), .alreadySatisfied)

        let moved = islandContext(spoofState: .active, needsSwitch: true)
        XCTAssertEqual(IslandCommandRouter.decide("switchHere", context: moved), .run)
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: moved), .run)

        let verifying = islandContext(spoofState: .verifying, spotSwitchPending: true)
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: verifying), .alreadySatisfied)
        XCTAssertEqual(IslandCommandRouter.decide("switchHere", context: verifying), .alreadySatisfied)

        let stopping = islandContext(spoofState: .verifying, spotStopPending: true)
        XCTAssertEqual(IslandCommandRouter.decide("stopSpoof", context: stopping), .alreadySatisfied)

        let idle = islandContext(spoofState: .idle)
        XCTAssertEqual(IslandCommandRouter.decide("stopSpoof", context: idle), .alreadySatisfied)
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: idle), .run)
    }

    func testRetryResolvesToTheFailedCommand() {
        var failedStop = islandContext(spoofState: .active, retryCommand: "stopSpoof")
        XCTAssertEqual(IslandCommandRouter.resolve("retry", context: failedStop), "stopSpoof")
        XCTAssertEqual(IslandCommandRouter.decide("stopSpoof", context: failedStop), .run)

        failedStop.retryCommand = ""
        failedStop.interruption = .activationFailed
        failedStop.routePhase = .preparing
        XCTAssertEqual(IslandCommandRouter.resolve("retry", context: failedStop), "play")
        XCTAssertEqual(IslandCommandRouter.decide("play", context: failedStop), .run)

        let unknown = islandContext()
        XCTAssertEqual(IslandCommandRouter.resolve("retry", context: unknown), "retry")
        XCTAssertEqual(
            IslandCommandRouter.decide("retry", context: unknown),
            .unavailable("没有可重试的操作。")
        )
    }

    func testStaleQuietPhasesCanRecoverWithoutResuming() {
        let staleRetrying = RouteIslandActions.buttons(
            phase: "retrying",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(staleRetrying.primaryAction, "retry")
        XCTAssertEqual(staleRetrying.secondaryAction, "openApp")

        let stalePlanning = RouteIslandActions.buttons(
            phase: "planning",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(stalePlanning.primaryAction, "openApp")

        let staleFinished = RouteIslandActions.buttons(
            phase: "finished",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(staleFinished.primaryAction, "")

        let staleStopped = RouteIslandActions.buttons(
            phase: "stopped",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopSpoof",
            secondaryTitle: "停止虚拟定位",
            isStale: true
        )
        XCTAssertEqual(staleStopped.primaryAction, "")
        XCTAssertNotEqual(staleStopped.secondaryAction, "stopSpoof")

        let staleVerifying = SpotIslandActions.buttons(
            phase: "verifying",
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: "",
            isStale: true
        )
        XCTAssertEqual(staleVerifying.primaryAction, "openApp")
        XCTAssertEqual(staleVerifying.secondaryAction, "")
    }

    func testFinishedHoldAndRecoveryDoNotBlockTheNextActivity() {
        XCTAssertFalse(ActivityRunPolicy.blocksNewWork(holdingFinished: true))
        XCTAssertFalse(ActivityRunPolicy.blocksNewWork(holdingFinished: false))
        XCTAssertTrue(ActivityRunPolicy.shouldDismissWithoutSnapshot(keepForRecovery: true))
        XCTAssertEqual(ActivityRunPolicy.launchDecision(hasRecoverableSession: true), .endStale)
        XCTAssertEqual(ActivityRunPolicy.launchDecision(hasRecoverableSession: false), .endStale)
        XCTAssertTrue(ActivityRunPolicy.shouldReplace(nil))
        XCTAssertTrue(ActivityRunPolicy.shouldReplace(.ended))
        XCTAssertTrue(ActivityRunPolicy.shouldReplace(.dismissed))
        XCTAssertFalse(ActivityRunPolicy.shouldReplace(.active))
        XCTAssertFalse(ActivityRunPolicy.shouldReplace(.stale))
        XCTAssertFalse(ActivityRunPolicy.updateAccepted(.ended))
        XCTAssertTrue(ActivityRunPolicy.updateAccepted(.active))
        XCTAssertTrue(ActivityRunPolicy.updateAccepted(.stale))
        XCTAssertEqual(ActivityRunPolicy.idsToEnd(existing: ["old", "new"], keeping: "new"), ["old"])
        XCTAssertTrue(ActivityRunPolicy.shouldPublish(contentChanged: false, runtime: .stale))
        XCTAssertFalse(ActivityRunPolicy.shouldPublish(contentChanged: false, runtime: .active))
        XCTAssertTrue(ActivityRunPolicy.shouldPublish(contentChanged: true, runtime: .active))
        XCTAssertTrue(ActivityRunPolicy.shouldPublish(contentChanged: false, runtime: nil, activityMissing: true))
        XCTAssertFalse(IslandHandoffPolicy.opensAppToDeliver(canContinueInForeground: true))
        XCTAssertTrue(IslandHandoffPolicy.opensAppToDeliver(canContinueInForeground: false))
        XCTAssertEqual(ActivityRunPolicy.creationPlan(failureCount: 1), .retryImmediately)
        XCTAssertEqual(ActivityRunPolicy.creationPlan(failureCount: 2), .retryLater)
        XCTAssertEqual(ActivityRunPolicy.creationPlan(failureCount: 3), .stop)
        XCTAssertTrue(ActivityRunPolicy.shouldResetCreationFailures(previousKey: nil, key: "spot:locating:stopSpoof"))
        XCTAssertFalse(
            ActivityRunPolicy.shouldResetCreationFailures(
                previousKey: "spot:locating:stopSpoof",
                key: "spot:locating:stopSpoof"
            )
        )
        XCTAssertTrue(
            ActivityRunPolicy.shouldResetCreationFailures(
                previousKey: "spot:locating:stopSpoof",
                key: "route:playing:pause"
            )
        )
        XCTAssertEqual(ActivityRunPolicy.idsToEnd(existing: ["left", "kept"], keeping: nil), ["left", "kept"])
        XCTAssertTrue(IslandCommandHandoff.needsForeground(.queued))
        XCTAssertFalse(IslandCommandHandoff.needsForeground(.performed))
        XCTAssertFalse(IslandCommandHandoff.needsForeground(.rejected))
        XCTAssertFalse(IslandCommandHandoff.needsForeground(.duplicate))
        XCTAssertTrue(RoutePlaybackDeferral.waitsForSpotVerification(isVerifying: true, usesDeveloperTunnel: false))
        XCTAssertFalse(RoutePlaybackDeferral.waitsForSpotVerification(isVerifying: true, usesDeveloperTunnel: true))
        XCTAssertFalse(RoutePlaybackDeferral.waitsForSpotVerification(isVerifying: false, usesDeveloperTunnel: false))
        XCTAssertTrue(ActivityRunPolicy.shouldRetryCreationOnForeground(activityMissing: true, failureCount: 3))
        XCTAssertTrue(ActivityRunPolicy.shouldRetryCreationOnForeground(activityMissing: true, failureCount: 1))
        XCTAssertFalse(ActivityRunPolicy.shouldRetryCreationOnForeground(activityMissing: true, failureCount: 0))
        XCTAssertFalse(ActivityRunPolicy.shouldRetryCreationOnForeground(activityMissing: false, failureCount: 3))
    }

    func testBackgroundIntentsOpenTheAppWhenContinueIsUnavailable() {
        guard #available(iOS 17.0, *) else { return }
        XCTAssertFalse(IslandCommandIntent.openAppWhenRun)
        XCTAssertTrue(IslandOpeningCommandIntent.openAppWhenRun)
        XCTAssertTrue(IslandOpenAppIntent.openAppWhenRun)
        XCTAssertTrue(IslandCommandHandoff.needsForeground(.queued))
        XCTAssertTrue(IslandHandoffPolicy.opensAppToDeliver(canContinueInForeground: false))
        XCTAssertFalse(IslandHandoffPolicy.opensAppToDeliver(canContinueInForeground: true))
    }

    func testStaleUserPauseKeepsResumeAndOpenApp() {
        let buttons = RouteIslandActions.buttons(
            phase: "userPaused",
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线",
            isStale: true
        )
        XCTAssertEqual(buttons.primaryAction, "resume")
        XCTAssertEqual(buttons.primaryTitle, "继续")
        XCTAssertEqual(buttons.secondaryAction, "openApp")
        XCTAssertNotEqual(buttons.primaryAction, "stopRoute")
    }

    func testBlockedLocationDoesNotStartSpot() {
        let message = "免费签名已过期，请用电脑重新签名并安装。"
        let idle = islandContext(
            spoofState: .idle,
            locationBlocked: true,
            locationBlockMessage: message
        )
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: idle), .unavailable(message))

        let moved = islandContext(
            spoofState: .active,
            needsSwitch: true,
            locationBlocked: true,
            locationBlockMessage: message
        )
        XCTAssertEqual(IslandCommandRouter.decide("switchHere", context: moved), .unavailable(message))

        let locating = islandContext(
            spoofState: .active,
            locationBlocked: true,
            locationBlockMessage: message
        )
        XCTAssertEqual(IslandCommandRouter.decide("stopSpoof", context: locating), .run)
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: locating), .alreadySatisfied)

        let blank = islandContext(locationBlocked: true, locationBlockMessage: "  ")
        XCTAssertEqual(IslandCommandRouter.decide("begin", context: blank), .unavailable("现在不能开始定位。"))
    }

    @MainActor
    func testExpiredCommandIsReportedInsteadOfRunning() {
        let suite = "island-expired-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previousDefaults = RouteActivityCommandStore.defaults
        let previousNow = RouteActivityCommandStore.now
        RouteActivityCommandStore.defaults = defaults
        RouteActivityBridge.handler = nil
        RouteActivityBridge.expirationHandler = nil
        RouteActivityBridge.inFlightAction = nil
        defer {
            RouteActivityCommandStore.defaults = previousDefaults
            RouteActivityCommandStore.now = previousNow
            defaults.removePersistentDomain(forName: suite)
            RouteActivityBridge.handler = nil
            RouteActivityBridge.expirationHandler = nil
            RouteActivityBridge.inFlightAction = nil
        }

        let issued = Date(timeIntervalSince1970: 2_000)
        RouteActivityCommandStore.now = { issued }
        XCTAssertEqual(RouteActivityBridge.submit("resume"), .queued)
        RouteActivityCommandStore.now = { issued.addingTimeInterval(RouteActivityCommandStore.maxAge + 1) }

        var ran = false
        var expired: String?
        RouteActivityBridge.handler = { _ in ran = true }
        RouteActivityBridge.expirationHandler = { action in expired = action }
        RouteActivityBridge.drainPending()
        XCTAssertFalse(ran)
        XCTAssertEqual(expired, "resume")
        XCTAssertNil(RouteActivityCommandStore.peek())
        XCTAssertNil(RouteActivityCommandStore.takeExpiredAction())
    }

    @MainActor
    func testBridgeKeepsCommandUntilHandlerExistsAndDropsInvalidOrDuplicate() {
        let suite = "island-bridge-\(UUID().uuidString)"
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

        XCTAssertEqual(RouteActivityBridge.submit("not-an-action"), .rejected)
        XCTAssertNil(RouteActivityCommandStore.peek())

        XCTAssertEqual(RouteActivityBridge.submit("stopRoute"), .queued)
        XCTAssertEqual(RouteActivityCommandStore.peek(), "stopRoute")

        var runs = 0
        RouteActivityBridge.handler = { action in
            runs += 1
            XCTAssertEqual(action, "stopRoute")
            XCTAssertEqual(RouteActivityBridge.submit("stopRoute"), .duplicate)
        }
        RouteActivityBridge.drainPending()
        XCTAssertEqual(runs, 1)
        XCTAssertNil(RouteActivityCommandStore.peek())
    }

    private func islandContext(
        routePhase: RoutePhase = .inactive,
        interruption: RouteInterruption = .playing,
        statusMessage: String = "",
        waitingForActivation: Bool = false,
        spoofState: SpoofState = .idle,
        needsSwitch: Bool = false,
        spotStopPending: Bool = false,
        spotSwitchPending: Bool = false,
        retryCommand: String = "",
        locationBlocked: Bool = false,
        locationBlockMessage: String = ""
    ) -> IslandCommandContext {
        IslandCommandContext(
            routePhase: routePhase,
            interruption: interruption,
            statusMessage: statusMessage,
            waitingForActivation: waitingForActivation,
            spoofState: spoofState,
            needsSwitch: needsSwitch,
            spotStopPending: spotStopPending,
            spotSwitchPending: spotSwitchPending,
            retryCommand: retryCommand,
            locationBlocked: locationBlocked,
            locationBlockMessage: locationBlockMessage
        )
    }
}
