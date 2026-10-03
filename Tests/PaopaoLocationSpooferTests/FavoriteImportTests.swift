import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class FavoriteImportTests: XCTestCase {
    private func favorite(_ latitude: Double = 1, name: String = "合成", accuracy: Int = 25) -> FavoriteLocation {
        FavoriteLocation(name: name, coordinatePair: CoordinatePair(
            wgs84: .init(latitude: latitude, longitude: 2),
            gcj02: .init(latitude: latitude, longitude: 2)
        ), accuracy: accuracy, createdAt: Date(timeIntervalSince1970: 100))
    }

    private func store() -> FavoriteLocationStore {
        let suite = "FavoriteImportTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return FavoriteLocationStore(defaults: defaults)
    }

    private func text() throws -> String {
        String(decoding: try FavoriteTransfer.encode([favorite()]), as: UTF8.self)
    }

    func testClipboardAndFileUseSamePreparationAndCommit() async throws {
        let text = try text()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        for input in [FavoriteImportPreparation.Input.clipboard(text), .file(url)] {
            let coordinator = FavoriteImportCoordinator(), target = store()
            XCTAssertTrue(coordinator.start(input, isPageActive: { true }, commit: target.importPrepared))
            await coordinator.waitForCompletion()
            XCTAssertEqual(target.favorites.map(\.name), ["合成"])
            XCTAssertEqual(coordinator.notice?.title, "收藏已导入")
            XCTAssertFalse(coordinator.isBusy)
        }
    }

    func testMainActorResponsiveAndRepeatedClicksDoNotAccumulateWork() async throws {
        let gate = ImportGate(), coordinator = FavoriteImportCoordinator(), target = store()
        let prepared = try FavoriteTransfer.prepare([favorite()])
        let page = UUID()
        coordinator.enterPage(page)
        let start = {
            coordinator.start(.clipboard("snapshot"), isPageActive: { true }, prepare: { _ in
                await gate.pause()
                return prepared
            }, commit: target.importPrepared)
        }
        XCTAssertTrue(start())
        await gate.waitUntilEntered()
        coordinator.enterPage(page)
        XCTAssertEqual(coordinator.state, .preparing)
        for _ in 0..<20 { XCTAssertFalse(start()) }
        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .cancelling)
        for _ in 0..<20 { XCTAssertFalse(start()) }
        await gate.release()
        await coordinator.waitForCompletion()
        XCTAssertTrue(target.favorites.isEmpty)
        XCTAssertNil(coordinator.notice)
        XCTAssertTrue(coordinator.start(.clipboard(try text()), isPageActive: { true }, commit: target.importPrepared))
        await coordinator.waitForCompletion()
        XCTAssertEqual(target.favorites.count, 1)
    }

    func testLeavingAndReenteringRejectsLateSuccessAndFailure() async throws {
        for fail in [false, true] {
            let gate = ImportGate(), coordinator = FavoriteImportCoordinator(), target = store()
            let prepared = try FavoriteTransfer.prepare([favorite()])
            var active = true
            coordinator.start(.clipboard("snapshot"), isPageActive: { active }, prepare: { _ in
                await gate.pause()
                if fail { throw URLError(.fileDoesNotExist) }
                return prepared
            }, commit: target.importPrepared)
            await gate.waitUntilEntered()
            active = false
            coordinator.leavePage()
            active = true
            await gate.release()
            await coordinator.waitForCompletion()
            XCTAssertTrue(target.favorites.isEmpty)
            XCTAssertNil(coordinator.notice)
            coordinator.start(.clipboard(try text()), isPageActive: { active }, commit: target.importPrepared)
            await coordinator.waitForCompletion()
            XCTAssertEqual(coordinator.notice?.title, "收藏已导入")
        }
    }

    func testPickerReturnKeepsPageIdentityButOldPageCallbackCannotStartAfterReentry() async throws {
        let coordinator = FavoriteImportCoordinator(), target = store()
        let old = UUID(), new = UUID()
        coordinator.enterPage(old)
        // 文件选择器/临时 sheet 引起的重复出现不创建新会话，也不取消当前任务。
        coordinator.enterPage(old)
        XCTAssertTrue(coordinator.ownsPage(old))
        coordinator.start(.clipboard(try text()), isPageActive: { coordinator.ownsPage(old) }, commit: target.importPrepared)
        await coordinator.waitForCompletion()
        XCTAssertEqual(target.favorites.count, 1)
        coordinator.leavePage()
        coordinator.enterPage(new)
        XCTAssertFalse(coordinator.start(.clipboard(try text()), isPageActive: {
            coordinator.ownsPage(old)
        }, commit: target.importPrepared))
        XCTAssertTrue(coordinator.ownsPage(new))
        XCTAssertNil(coordinator.notice)
    }

    func testPagePredicateBlocksCommitEvenBeforeLifecycleCallback() async throws {
        let gate = ImportGate(), coordinator = FavoriteImportCoordinator(), target = store()
        let prepared = try FavoriteTransfer.prepare([favorite()])
        var active = true
        coordinator.start(.clipboard("snapshot"), isPageActive: { active }, prepare: { _ in
            await gate.pause(); return prepared
        }, commit: target.importPrepared)
        await gate.waitUntilEntered()
        active = false
        await gate.release()
        await coordinator.waitForCompletion()
        XCTAssertTrue(target.favorites.isEmpty)
        XCTAssertNil(coordinator.notice)
    }

    func testPreparationRunsOffMainThreadAndCommitsLatestStore() async throws {
        let gate = ImportGate(), coordinator = FavoriteImportCoordinator(), target = store()
        let input = try text()
        coordinator.start(.clipboard(input), isPageActive: { true }, prepare: { input in
            XCTAssertFalse(Thread.isMainThread)
            let prepared = try FavoriteImportPreparation.prepare(input)
            await gate.pause()
            return prepared
        }, commit: { prepared in
            XCTAssertTrue(Thread.isMainThread)
            return target.importPrepared(prepared)
        })
        await gate.waitUntilEntered()
        let added = target.save(name: "期间新增", coordinatePair: favorite(3).coordinatePair, accuracy: 30)
        await gate.release()
        await coordinator.waitForCompletion()
        XCTAssertEqual(target.favorites.count, 2)
        XCTAssertTrue(target.favorites.contains { $0.id == added.id && $0.name == "期间新增" })
    }

    func testCancellationAtRealPreparationBoundariesNeverCommits() async throws {
        let text = String(decoding: try FavoriteTransfer.encode((0..<4).map { favorite(Double($0)) }), as: UTF8.self)
        for stage in [FavoriteImportPreparation.Stage.afterRead, .converting, .deduplicating, .prepared] {
            let gate = BlockingImportGate(), coordinator = FavoriteImportCoordinator(), target = store()
            coordinator.start(.clipboard(text), isPageActive: { true }, prepare: { input in
                var hits = 0
                return try FavoriteImportPreparation.prepare(input) { current in
                    if current == stage {
                        hits += 1
                        let targetHit = stage == .converting ? 4 : (stage == .deduplicating ? 7 : 1)
                        if hits == targetHit { gate.pauseOnce() }
                    }
                    try Task.checkCancellation()
                }
            }, commit: target.importPrepared)
            await gate.waitUntilEntered()
            coordinator.cancel()
            gate.release()
            await coordinator.waitForCompletion()
            XCTAssertTrue(target.favorites.isEmpty)
            XCTAssertNil(coordinator.notice)
        }
    }

    func testFileAccessReleasedBeforeDecodeAndOnReadFailure() throws {
        let data = Data(try text().utf8), url = URL(fileURLWithPath: "/synthetic")
        for fails in [false, true] {
            var begins = 0, ends = 0
            let access = FavoriteImportPreparation.FileAccess(begin: { _ in begins += 1; return true },
                end: { _ in ends += 1 }, read: { _ in
                    if fails { throw URLError(.fileDoesNotExist) }
                    return data
                })
            do {
                _ = try FavoriteImportPreparation.prepare(.file(url), access: access) { stage in
                    if stage == .decoding { XCTAssertEqual(ends, 1) }
                }
                XCTAssertFalse(fails)
            } catch { XCTAssertTrue(fails) }
            XCTAssertEqual(begins, 1)
            XCTAssertEqual(ends, 1)
        }
    }

    func testCancelDuringUninterruptibleReadBalancesAccess() async throws {
        let gate = BlockingImportGate(), coordinator = FavoriteImportCoordinator(), target = store()
        let data = Data(try text().utf8)
        let released = expectation(description: "访问权释放")
        coordinator.start(.file(URL(fileURLWithPath: "/synthetic")), isPageActive: { true }, prepare: { input in
            let access = FavoriteImportPreparation.FileAccess(begin: { _ in true }, end: { _ in
                released.fulfill()
            }, read: { _ in gate.pauseOnce(); return data })
            return try FavoriteImportPreparation.prepare(input, access: access)
        }, commit: target.importPrepared)
        await gate.waitUntilEntered()
        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .cancelling)
        gate.release()
        await coordinator.waitForCompletion()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertTrue(target.favorites.isEmpty)
    }

    func testInvalidInputShowsRealErrorAndDoesNotCommit() async throws {
        for input in ["not-json", try String(decoding: FavoriteTransfer.encode([favorite(), favorite(2, accuracy: 101)]), as: UTF8.self)] {
            let coordinator = FavoriteImportCoordinator(), target = store()
            coordinator.start(.clipboard(input), isPageActive: { true }, commit: target.importPrepared)
            await coordinator.waitForCompletion()
            XCTAssertEqual(coordinator.notice?.title, "收藏导入失败")
            XCTAssertTrue(target.favorites.isEmpty)
        }
    }

    func testMissingFileReportsReadFailureAndReleasesSlot() async {
        let coordinator = FavoriteImportCoordinator(), target = store()
        coordinator.start(.file(URL(fileURLWithPath: "/nonexistent-\(UUID())")),
                          isPageActive: { true }, commit: target.importPrepared)
        await coordinator.waitForCompletion()
        XCTAssertEqual(coordinator.notice?.title, "收藏导入失败")
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertTrue(target.favorites.isEmpty)
    }

    func testDeniedScopeIsNotReleasedAndCancellationBeforeReadDoesNotAcquire() throws {
        var acquired = 0, released = 0, reads = 0
        let access = FavoriteImportPreparation.FileAccess(begin: { _ in acquired += 1; return false },
            end: { _ in released += 1 }, read: { _ in reads += 1; throw URLError(.fileDoesNotExist) })
        let input = FavoriteImportPreparation.Input.file(URL(fileURLWithPath: "/synthetic"))
        XCTAssertThrowsError(try FavoriteImportPreparation.prepare(input, access: access))
        XCTAssertEqual(acquired, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(released, 0)
        XCTAssertThrowsError(try FavoriteImportPreparation.prepare(input, access: access) { _ in
            throw CancellationError()
        })
        XCTAssertEqual(acquired, 1)
        XCTAssertEqual(reads, 1)
    }

    func testCancellationOnceSynchronousCommitStartsDoesNotRollback() async throws {
        let coordinator = FavoriteImportCoordinator(), target = store()
        coordinator.start(.clipboard(try text()), isPageActive: { true }) { prepared in
            let result = target.importPrepared(prepared)
            coordinator.cancel()
            return result
        }
        await coordinator.waitForCompletion()
        XCTAssertEqual(target.favorites.count, 1)
        XCTAssertNil(coordinator.notice)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testNonTransitiveDedupPreservesFirstIDDateAndLastCoordinates() throws {
        let a = favorite(0, name: "A"), b = favorite(0.00000075, name: "B"), c = favorite(0.0000015, name: "C")
        let result = try FavoriteTransfer.prepare([a, b, c])
        XCTAssertEqual(result.skippedDuplicates, 2)
        XCTAssertEqual(result.favorites.count, 1)
        XCTAssertEqual(result.favorites[0].id, a.id)
        XCTAssertEqual(result.favorites[0].createdAt, a.createdAt)
        XCTAssertEqual(result.favorites[0].name, "C")
        XCTAssertEqual(result.favorites[0].coordinatePair, c.coordinatePair)
        let reordered = try FavoriteTransfer.prepare([a, c, b])
        XCTAssertEqual(reordered.favorites.map(\.name), ["B", "C"])
        XCTAssertEqual(try FavoriteTransfer.prepare([a, favorite(0.000001)]).favorites.count, 2)
    }

    func testCapacityLateUpdateSelectionAndRepeatedImport() throws {
        let target = store()
        let existing = (0..<300).map { favorite(Double($0) * 0.01, name: "原\($0)") }
        try target.importTransferred(existing)
        target.select(existing[0].id)
        let incoming = [favorite(80), favorite(0, name: "更新")]
        let prepared = try FavoriteTransfer.prepare(incoming)
        for _ in 0..<2 {
            let result = target.importPrepared(prepared)
            XCTAssertEqual(result, .init(added: 0, updated: 1, skippedDuplicates: 0, skippedOverLimit: 1))
            XCTAssertEqual(target.favorites.count, 300)
            XCTAssertEqual(target.favorites[0].id, existing[0].id)
            XCTAssertEqual(target.favorites[0].createdAt, existing[0].createdAt)
            XCTAssertEqual(target.selectedFavoriteID, existing[0].id)
            XCTAssertEqual(target.favorites[0].name, "更新")
        }
    }

    func testTypedPreparationRejectsCoordinatesAndLateInvalidAccuracy() throws {
        let target = store()
        let valid = (0..<350).map { favorite(Double($0) * 0.01) }
        for invalid in [favorite(.nan), favorite(91), favorite(1, accuracy: 4)] {
            XCTAssertThrowsError(try target.importTransferred(valid + [invalid]))
            XCTAssertTrue(target.favorites.isEmpty)
        }
    }
}

private actor ImportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation = $0; entered?.resume(); entered = nil }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// 只在测试中阻塞后台执行点，主 actor 通过 continuation 接收已到达通知。
private final class BlockingImportGate {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?
    func pauseOnce() {
        condition.lock()
        defer { condition.unlock() }
        guard !entered else { return }
        entered = true
        observer?.resume(); observer = nil
        while !released { condition.wait() }
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { continuation.resume() } else { observer = continuation }
            condition.unlock()
        }
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}
