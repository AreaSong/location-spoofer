import XCTest
import Combine
@testable import PaopaoLocationSpoofer

@MainActor
final class RouteImportCoordinatorTests: RouteImportTestCase {
    func testPublishedPreparingCannotReenterAndStartAnotherWorker() async throws {
        let coordinator = RouteImportCoordinator(), page = UUID()
        let (store, _, _) = isolatedStore()
        let text = try RouteImportSamples.json([RouteImportSamples.route()])
        coordinator.enterPage(page)
        var reentered = false
        var duplicateAccepted = false
        let observer = coordinator.$state.sink { state in
            if state == .preparing && !reentered {
                reentered = true
                duplicateAccepted = coordinator.start(.clipboard(text), pageID: page, isPageActive: { true }) {
                    store.importTransferred($0.routes)
                }
            }
        }
        await run(text, coordinator: coordinator, page: page, store: store)
        XCTAssertTrue(reentered)
        XCTAssertFalse(duplicateAccepted)
        withExtendedLifetime(observer) {}
    }

    func testPublishedCommittingExitOrCancellationPreventsCommit() async throws {
        for exit in [true, false] {
            let coordinator = RouteImportCoordinator(), page = UUID()
            let (store, _, _) = isolatedStore()
            coordinator.enterPage(page)
            let observer = coordinator.$state.sink { state in
                if state == .committing {
                    if exit { coordinator.leavePage(page) } else { coordinator.cancel() }
                }
            }
            await run(try RouteImportSamples.json([RouteImportSamples.route()]), coordinator: coordinator, page: page, store: store)
            XCTAssertTrue(store.routes.isEmpty)
            XCTAssertNil(coordinator.notice)
            XCTAssertEqual(coordinator.state, .idle)
            withExtendedLifetime(observer) {}
        }
    }

    func testRealPreparationLeavesMainActorAndCancelRetainsSingleSlotUntilReadReturns() async throws {
        let gate = RouteImportGate(), coordinator = RouteImportCoordinator(), page = UUID()
        let (store, _, _) = isolatedStore()
        let text = try RouteImportSamples.json([RouteImportSamples.route()])
        let ended = expectation(description: "读取访问权释放")
        coordinator.enterPage(page)
        XCTAssertTrue(coordinator.start(.file(URL(fileURLWithPath: "/synthetic")), pageID: page,
            isPageActive: { true }, prepare: { input in
                try RouteImportPreparation.prepare(input, access: .init(begin: { _ in true }, end: { _ in ended.fulfill() }, read: { _ in
                    XCTAssertFalse(Thread.isMainThread)
                    gate.pauseOnce()
                    return Data(text.utf8)
                }))
            }, commit: { store.importTransferred($0.routes) }))
        await gate.waitUntilEntered()
        // 能运行到此处即证明真实读取挂起期间主 actor 能处理用户操作。
        coordinator.cancel()
        coordinator.leavePage(page)
        let nextPage = UUID()
        coordinator.enterPage(nextPage)
        XCTAssertEqual(coordinator.state, .cancelling)
        for _ in 0..<30 {
            XCTAssertFalse(coordinator.start(.clipboard(text), pageID: nextPage, isPageActive: { true }) {
                store.importTransferred($0.routes)
            })
        }
        gate.release()
        await coordinator.waitForCompletion()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertTrue(store.routes.isEmpty)
        XCTAssertNil(coordinator.notice)
        await run(text, coordinator: coordinator, page: nextPage, store: store)
        XCTAssertEqual(store.routes.count, 1)
        XCTAssertEqual(coordinator.notice?.title, "路线已导入")
    }

    func testCancellationAfterReadDuringXMLConversionSimplificationAndBeforeCommit() async throws {
        for format in ["gpx", "kml", "json"] {
            let text = format == "json" ? try RouteImportSamples.json([RouteImportSamples.route(count: 1000)])
                : RouteImportSamples.xml(format)
            var stages: [RouteImportPreparation.Stage] = [.afterRead, .converting, .simplificationStep, .prepared]
            if format != "json" { stages.append(.parsing) }
            for stage in stages {
                let gate = RouteImportGate(), coordinator = RouteImportCoordinator(), page = UUID()
                let (store, _, _) = isolatedStore()
                coordinator.enterPage(page)
                coordinator.start(.clipboard(text), pageID: page, isPageActive: { true }, prepare: { input in
                    var hits = 0
                    var largePath = false
                    return try RouteImportPreparation.prepare(input) { current in
                        if case .simplifying(let count) = current { largePath = count > 400 }
                        if current == stage {
                            hits += 1
                            let ready = stage == .converting ? hits == 20 : stage == .parsing ? hits == 3
                                : stage == .simplificationStep ? largePath && hits > 1 : true
                            if ready { gate.pauseOnce() }
                        }
                        try Task.checkCancellation()
                    }
                }, commit: { store.importTransferred($0.routes) })
                await gate.waitUntilEntered()
                coordinator.cancel()
                gate.release()
                await coordinator.waitForCompletion()
                XCTAssertTrue(store.routes.isEmpty, "\(format) \(stage)")
                XCTAssertNil(coordinator.notice)
                XCTAssertEqual(coordinator.state, .idle)
            }
        }
    }

    func testPageExitRejectsLateSuccessAndFailureAndDoesNotEraseNewNotice() async throws {
        for fails in [false, true] {
            let gate = RouteImportGate(), coordinator = RouteImportCoordinator(), page = UUID()
            let (store, _, _) = isolatedStore()
            let text = try RouteImportSamples.json([RouteImportSamples.route()])
            coordinator.enterPage(page)
            coordinator.start(.clipboard(text), pageID: page, isPageActive: { true }, prepare: { input in
                let prepared = try RouteImportPreparation.prepare(input)
                gate.pauseOnce() // 模拟不可中断能力忽略取消，成功或失败迟到。
                if fails { throw CocoaError(.fileReadCorruptFile) }
                return prepared
            }, commit: { store.importTransferred($0.routes) })
            await gate.waitUntilEntered()
            coordinator.leavePage(page)
            let nextPage = UUID()
            coordinator.enterPage(nextPage)
            coordinator.report("新页面", "保留新反馈")
            coordinator.leavePage(page) // 旧页面迟到退出不能关闭新页面。
            gate.release()
            await coordinator.waitForCompletion()
            XCTAssertTrue(store.routes.isEmpty)
            XCTAssertTrue(coordinator.ownsPage(nextPage))
            XCTAssertEqual(coordinator.notice?.title, "新页面")
        }
    }

    func testCommitRechecksPresentationEvenBeforeHostExitNotification() async throws {
        let gate = RouteImportGate(), coordinator = RouteImportCoordinator(), page = UUID()
        let (store, _, _) = isolatedStore()
        var presented = true
        coordinator.enterPage(page)
        coordinator.start(.clipboard(RouteImportSamples.xml("gpx")), pageID: page,
            isPageActive: { presented }, prepare: { input in
                let prepared = try RouteImportPreparation.prepare(input)
                gate.pauseOnce()
                return prepared
            }, commit: { store.importTransferred($0.routes) })
        await gate.waitUntilEntered()
        presented = false
        gate.release()
        await coordinator.waitForCompletion()
        XCTAssertTrue(store.routes.isEmpty)
        XCTAssertNil(coordinator.notice)
    }

    func testTemporaryPresentationAndFileRequestIdentity() async throws {
        let coordinator = RouteImportCoordinator(), page = UUID()
        coordinator.enterPage(page)
        let old = try XCTUnwrap(coordinator.beginFileSelection(pageID: page))
        coordinator.enterPage(page) // 文件选择器/临时 sheet 返回时 onAppear 不取消会话。
        XCTAssertTrue(coordinator.ownsPage(page))
        XCTAssertTrue(coordinator.acceptFileSelection(old))
        XCTAssertFalse(coordinator.acceptFileSelection(old))
        let stale = try XCTUnwrap(coordinator.beginFileSelection(pageID: page))
        coordinator.leavePage(page)
        let next = UUID()
        coordinator.enterPage(next)
        let current = try XCTUnwrap(coordinator.beginFileSelection(pageID: next))
        XCTAssertFalse(coordinator.acceptFileSelection(stale))
        XCTAssertTrue(coordinator.acceptFileSelection(current))
        XCTAssertTrue(RouteImportCoordinator.isCancellation(CocoaError(.userCancelled)))
    }

    func testSheetDismissalBeforeFileCallbackAndSwipeThenRetry() throws {
        let coordinator = RouteImportCoordinator(), page = UUID()
        coordinator.enterPage(page)
        let picked = try XCTUnwrap(coordinator.beginFileSelection(pageID: page))
        // 系统关闭临时 sheet 不等于退出页面；随后到达的选择仍然有效。
        coordinator.enterPage(page)
        XCTAssertTrue(coordinator.acceptFileSelection(picked))
        let swiped = try XCTUnwrap(coordinator.beginFileSelection(pageID: page))
        let retried = try XCTUnwrap(coordinator.beginFileSelection(pageID: page))
        XCTAssertFalse(coordinator.acceptFileSelection(swiped))
        XCTAssertTrue(coordinator.acceptFileSelection(retried))
    }

    func testStoreModificationDuringPreparationIsPreserved() async throws {
        let gate = RouteImportGate(), coordinator = RouteImportCoordinator(), page = UUID()
        let (store, defaults, directory) = isolatedStore()
        let original = try store.save(RouteImportSamples.route(1))
        let text = try RouteImportSamples.json([RouteImportSamples.route(2)])
        coordinator.enterPage(page)
        coordinator.start(.clipboard(text), pageID: page, isPageActive: { true }, prepare: { input in
            let prepared = try RouteImportPreparation.prepare(input)
            gate.pauseOnce()
            return prepared
        }, commit: { store.importTransferred($0.routes) })
        await gate.waitUntilEntered()
        try store.rename(original.id, to: "准备期间合法改名")
        try store.save(RouteImportSamples.route(3, name: "准备期间新增"))
        gate.release()
        await coordinator.waitForCompletion()
        XCTAssertEqual(store.routes.map(\.name), ["合成路线", "准备期间新增", "准备期间合法改名"])
        XCTAssertEqual(SavedRouteStore(defaults: defaults, pathDirectory: directory).routes, store.routes)
    }

    func testSynchronousCommitCancellationKeepsActualPartialSuccessCounts() async throws {
        let coordinator = RouteImportCoordinator(), page = UUID()
        let first = RouteImportSamples.route(1), second = RouteImportSamples.route(2)
        let (store, _, _) = isolatedStore { id in
            coordinator.cancel()
            if id == second.id { throw CocoaError(.fileWriteOutOfSpace) }
        }
        coordinator.enterPage(page)
        await run(try RouteImportSamples.json([first, second]), coordinator: coordinator, page: page, store: store)
        XCTAssertEqual(store.routes.map(\.id), [first.id])
        XCTAssertEqual(coordinator.notice?.title, "路线部分导入")
        XCTAssertEqual(coordinator.notice?.message, "新增 1 条，更新 0 条，超出上限 0 条，失败 1 条")
        XCTAssertEqual(coordinator.state, .idle)
    }
}
