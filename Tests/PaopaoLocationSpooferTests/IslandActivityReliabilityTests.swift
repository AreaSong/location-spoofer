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
            RouteActivityBridge.inFlightAction = nil
        }
        RouteActivityBridge.handler = nil
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
        retryCommand: String = ""
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
            retryCommand: retryCommand
        )
    }
}
