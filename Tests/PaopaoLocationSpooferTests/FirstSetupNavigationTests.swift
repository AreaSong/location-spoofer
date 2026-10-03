import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class FirstSetupNavigationTests: XCTestCase {
    func testBackDuringSuccessFeedbackDoesNotAdvance() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        XCTAssertFalse(navigation.isPreviewVerifying, "成功反馈期间仍允许返回")
        navigation.returnToPreviousStep()
        gate.release(1)
        await task.value
        XCTAssertEqual(navigation.step, .mode)
        XCTAssertFalse(navigation.previewSucceeded)
    }

    func testExitDuringSuccessFeedbackDoesNotAdvance() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        navigation.disappear()
        gate.release(1)
        await task.value
        XCTAssertEqual(navigation.step, .proxy)
        XCTAssertFalse(navigation.previewSucceeded)
    }

    func testLeavingAndReenteringSameStepRejectsOldResult() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        navigation.returnToPreviousStep()
        navigation.step = .proxy
        gate.release(1)
        await task.value
        XCTAssertEqual(navigation.step, .proxy)
    }

    func testReselectingSameStepInvalidatesPendingIntent() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        navigation.step = .proxy
        gate.release(1)
        await task.value
        XCTAssertEqual(navigation.step, .proxy)
        XCTAssertFalse(navigation.previewSucceeded)
    }

    func testOldSuccessDoesNotClearNewBusyStateOrAdvance() async {
        await checkSupersededWait(error: nil)
    }

    func testOldFailureDoesNotClearNewBusyStateOrAdvance() async {
        await checkSupersededWait(error: TestError.failed)
    }

    func testOldCancellationDoesNotClearNewBusyStateOrAdvance() async {
        await checkSupersededWait(error: CancellationError())
    }

    func testBackOnLastStepDoesNotComplete() async {
        await checkLastStepExit(back: true)
    }

    func testExitOnLastStepDoesNotComplete() async {
        await checkLastStepExit(back: false)
    }

    func testDuplicateClicksAndValidCompletionAreConsumedOnce() async {
        let gate = SetupPreviewWaitGate()
        var completed = 0
        let navigation = FirstSetupNavigation(step: .cert, wait: gate.wait) { completed += 1 }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        XCTAssertNil(navigation.startPreviewCheck())
        await showSuccess(gate)
        gate.release(1)
        await task.value
        XCTAssertEqual(completed, 1)
        navigation.completePreview()
        XCTAssertEqual(completed, 1)
        // 不留下测试自身创建的等待。
        if let duplicate = navigation.startPreviewCheck() {
            await gate.reached(2)
            gate.release(2)
            await gate.reached(3)
            gate.release(3)
            await duplicate.value
            XCTFail("完成后的页面不得再开始操作")
        }
    }

    func testCancellationThrownByWaitDoesNotAdvance() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        gate.release(1, error: CancellationError())
        await task.value
        XCTAssertEqual(navigation.step, .proxy)
        XCTAssertFalse(navigation.isPreviewVerifying)
        XCTAssertFalse(navigation.previewSucceeded)
    }

    func testSuspendedTaskDoesNotRetainPageOwner() async {
        let gate = SetupPreviewWaitGate()
        var navigation: FirstSetupNavigation? = FirstSetupNavigation(step: .cert, wait: gate.wait) {
            XCTFail("销毁后不应完成")
        }
        weak var owner = navigation
        navigation?.appear()
        let task = navigation!.startPreviewCheck()!
        await showSuccess(gate)
        navigation = nil
        XCTAssertNil(owner)
        gate.release(1)
        await task.value
    }

    func testOldVerificationResponsesCannotClearRestartedOperation() async {
        for error in [nil, TestError.failed, CancellationError()] as [Error?] {
            let gate = SetupPreviewWaitGate()
            let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
            navigation.appear()
            let old = navigation.startPreviewCheck()!
            await gate.reached(0)
            navigation.disappear()
            navigation.appear()
            let current = navigation.startPreviewCheck()!
            await gate.reached(1)
            gate.release(0, error: error)
            await old.value
            XCTAssertTrue(navigation.isPreviewVerifying)
            XCTAssertFalse(navigation.previewSucceeded)
            XCTAssertEqual(navigation.step, .proxy)
            gate.release(1)
            await gate.reached(2)
            gate.release(2)
            await current.value
            XCTAssertEqual(navigation.step, .cert)
        }
    }

    func testDisappearingAndReappearingAtSameStepRejectsOldCompletion() async {
        let gate = SetupPreviewWaitGate()
        var completed = 0
        let navigation = FirstSetupNavigation(step: .thirdPartyImport, wait: gate.wait) { completed += 1 }
        navigation.appear()
        let old = navigation.startPreviewCheck()!
        await showSuccess(gate)
        navigation.disappear()
        navigation.appear()
        gate.release(1)
        await old.value
        XCTAssertEqual(completed, 0)
        let current = navigation.startPreviewCheck()!
        await gate.reached(2)
        gate.release(2)
        await gate.reached(3)
        gate.release(3)
        await current.value
        XCTAssertEqual(completed, 1)
    }

    func testFailureBeforeSuccessEndsOperationAndAllowsRetry() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await gate.reached(0)
        gate.release(0, error: TestError.failed)
        await task.value
        XCTAssertEqual(gate.calls, 1)
        XCTAssertFalse(navigation.isPreviewVerifying)
        XCTAssertFalse(navigation.previewSucceeded)
        let retry = navigation.startPreviewCheck()!
        await gate.reached(1)
        gate.release(1, error: CancellationError())
        await retry.value
    }

    func testExplicitTaskCancellationRejectsNonCooperativeWaitSuccess() async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        task.cancel()
        gate.release(1)
        await task.value
        XCTAssertEqual(navigation.step, .proxy)
        XCTAssertFalse(navigation.previewSucceeded)
        XCTAssertFalse(navigation.isPreviewVerifying)
    }

    func testExitCancelsActualSleepPromptly() async {
        let entered = expectation(description: "等待已开始")
        let exited = expectation(description: "睡眠被取消")
        let navigation = FirstSetupNavigation(step: .cert, wait: { _ in
            entered.fulfill()
            defer { exited.fulfill() }
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }) { XCTFail("不应完成") }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await fulfillment(of: [entered], timeout: 2)
        navigation.disappear()
        await fulfillment(of: [exited], timeout: 2)
        await task.value
        XCTAssertFalse(navigation.isPreviewVerifying)
    }

    func testValidTwoStepPreviewCompletesOnceWithoutApplyingRealVerification() async {
        let gate = SetupPreviewWaitGate()
        let setup = SetupCoordinator()
        setup.requestSetup()
        let navigation = FirstSetupNavigation(step: setup.setupStep, wait: gate.wait) { setup.completeSetup() }
        navigation.appear()
        let proxy = navigation.startPreviewCheck()!
        await showSuccess(gate)
        gate.release(1)
        await proxy.value
        XCTAssertEqual(navigation.step, .cert)
        XCTAssertTrue(setup.needsSetup)
        let cert = navigation.startPreviewCheck()!
        await gate.reached(2)
        gate.release(2)
        await gate.reached(3)
        gate.release(3)
        await cert.value
        XCTAssertFalse(setup.needsSetup)
        XCTAssertNil(setup.lastVerificationResult)
        XCTAssertEqual(setup.trustState, .checking)
        XCTAssertNil(navigation.startPreviewCheck())
    }

    func testFormalNavigationDoesNotTriggerPreviewCompletionOrFeedback() {
        let navigation = FirstSetupNavigation(step: .mode) { XCTFail("仅导航不能绕过正式验证") }
        navigation.appear()
        for step in SetupStep.allCases {
            navigation.step = step
            XCTAssertFalse(navigation.isPreviewVerifying)
            XCTAssertFalse(navigation.previewSucceeded)
        }
        navigation.returnToPreviousStep()
        XCTAssertEqual(navigation.step, .mode)
    }

    func testImmediateTunnelPreviewCompletionIsLimitedToActivePresentation() {
        var completed = 0
        let navigation = FirstSetupNavigation(step: .developerTunnel) { completed += 1 }
        navigation.completePreview()
        XCTAssertEqual(completed, 0)
        navigation.appear()
        navigation.completePreview()
        navigation.completePreview()
        XCTAssertEqual(completed, 1)
        navigation.disappear()
        navigation.completePreview()
        XCTAssertEqual(completed, 1)
        navigation.appear()
        navigation.completePreview()
        XCTAssertEqual(completed, 2)
    }

    private func showSuccess(_ gate: SetupPreviewWaitGate) async {
        await gate.reached(0)
        gate.release(0)
        await gate.reached(1)
    }

    private func checkLastStepExit(back: Bool) async {
        let gate = SetupPreviewWaitGate()
        var completed = 0
        let navigation = FirstSetupNavigation(step: .cert, wait: gate.wait) { completed += 1 }
        navigation.appear()
        let task = navigation.startPreviewCheck()!
        await showSuccess(gate)
        if back { navigation.returnToPreviousStep() } else { navigation.disappear() }
        gate.release(1)
        await task.value
        XCTAssertEqual(completed, 0)
    }

    private func checkSupersededWait(error: Error?) async {
        let gate = SetupPreviewWaitGate()
        let navigation = FirstSetupNavigation(step: .proxy, wait: gate.wait) { XCTFail("不应完成") }
        navigation.appear()
        let old = navigation.startPreviewCheck()!
        await showSuccess(gate)
        let current = navigation.startPreviewCheck()!
        await gate.reached(2)
        gate.release(1, error: error)
        await old.value
        XCTAssertTrue(navigation.isPreviewVerifying)
        XCTAssertFalse(navigation.previewSucceeded)
        XCTAssertEqual(navigation.step, .proxy)
        gate.release(2)
        await gate.reached(3)
        gate.release(3)
        await current.value
        XCTAssertEqual(navigation.step, .cert)
        XCTAssertFalse(navigation.isPreviewVerifying)
    }

    private enum TestError: Error { case failed }
}

/// 故意不响应 Task.cancel：证明迟到成功/失败也会被代次门禁拦下。
@MainActor
final class SetupPreviewWaitGate {
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var arrivals: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls = 0

    func wait(_ nanoseconds: UInt64) async throws {
        let index = calls
        calls += 1
        try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            arrivals.removeValue(forKey: index)?.resume()
        }
    }

    func reached(_ index: Int) async {
        if pending[index] != nil { return }
        await withCheckedContinuation { arrivals[index] = $0 }
    }

    func release(_ index: Int, error: Error? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else {
            XCTFail("等待 \(index) 尚未挂起")
            return
        }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
