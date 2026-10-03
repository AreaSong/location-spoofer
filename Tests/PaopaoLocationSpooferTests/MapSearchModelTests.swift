import XCTest
import MapKit
@testable import PaopaoLocationSpoofer

@MainActor
final class MapSearchModelTests: XCTestCase {
    func testNewSubmissionReplacesPendingSearch() async throws {
        let a = ControlledMapSearch()
        let b = ControlledMapSearch()
        let model = MapSearchModel { query, _ in query == "A" ? a : b }
        model.text = "A"
        let first = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await a.waitUntilStarted()
        model.text = "B"
        let second = model.submit(system: .gcj02, preferred: .wgs84)
        XCTAssertNotNil(second, "新提交必须替换挂起请求")
        if let second {
            await b.waitUntilStarted()
            b.succeed("B")
            await second.value
        }
        a.succeed("A")
        await first.value
        XCTAssertEqual(model.results.map(\.name), ["B"])
        XCTAssertTrue(a.cancelled)
    }

    func testSelectionInvalidatesPendingSearch() async throws {
        let request = ControlledMapSearch()
        let model = MapSearchModel { _, _ in request }
        model.text = "A"
        let task = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await request.waitUntilStarted()
        model.select(ControlledMapSearch.result("已选点"))
        request.succeed("迟到结果")
        await task.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.text, "已选点")
        XCTAssertTrue(request.cancelled)
    }

    func testLateFailureCannotReplaceNewSuccess() async throws {
        let a = ControlledMapSearch(), b = ControlledMapSearch()
        let model = MapSearchModel { query, _ in query == "A" ? a : b }
        model.text = "A"
        let first = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await a.waitUntilStarted()
        model.text = "B"
        let second = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await b.waitUntilStarted()
        b.succeed("B")
        await second.value
        a.fail(URLError(.notConnectedToInternet))
        await first.value
        XCTAssertEqual(model.results.map(\.name), ["B"])
        XCTAssertEqual(model.submittedQuery, "B")
        XCTAssertTrue(model.error.isEmpty)
    }

    func testClearCancelsWithoutShowingCancellationError() async throws {
        let request = ControlledMapSearch()
        let model = MapSearchModel { _, _ in request }
        model.text = "A"
        let task = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await request.waitUntilStarted()
        model.clear()
        request.fail(URLError(.cancelled))
        await task.value
        XCTAssertTrue(request.cancelled)
        XCTAssertTrue(model.text.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.submittedQuery)
    }

    func testClearDiscardsLateSuccess() async throws {
        let request = ControlledMapSearch()
        let model = MapSearchModel { _, _ in request }
        model.text = "A"
        let task = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await request.waitUntilStarted()
        model.clear()
        request.succeed("A")
        await task.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.error.isEmpty)
    }

    func testEditingHidesOldResultsAndReplacementCannotBeReopenedAfterSelection() async throws {
        let a = ControlledMapSearch(), b = ControlledMapSearch()
        let model = MapSearchModel { query, _ in query == "A" ? a : b }
        model.text = "A"
        let first = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await a.waitUntilStarted()
        a.succeed("地点A")
        await first.value
        let oldResult = try XCTUnwrap(model.results.first)
        model.text = "B"
        XCTAssertTrue(model.results.isEmpty, "编辑后旧结果不再可点")
        XCTAssertNil(model.submittedQuery)
        let second = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await b.waitUntilStarted()
        XCTAssertTrue(model.results.isEmpty)
        // 即使此前的控件动作已排队，选择仍必须终结 B。
        model.select(oldResult)
        b.succeed("地点B")
        await second.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(b.cancelled)
    }

    func testCoordinateInputReplacesPendingSearch() async throws {
        try await checkParsedReplacement("22.5, 113.9", expectedSystem: .gcj02, remembers: true)
    }

    func testMapLinkReplacesPendingSearch() async throws {
        try await checkParsedReplacement("https://maps.apple.com/?ll=22.5,113.9&q=测试点",
                                         expectedSystem: .wgs84, remembers: false)
    }

    private func checkParsedReplacement(
        _ text: String, expectedSystem: CoordinateConverter.MapCoordinateSystem, remembers: Bool
    ) async throws {
        let request = ControlledMapSearch()
        var requestCount = 0
        let model = MapSearchModel { _, _ in requestCount += 1; return request }
        model.text = "挂起"
        let first = try XCTUnwrap(model.submit(system: .wgs84, preferred: .gcj02))
        await request.waitUntilStarted()
        model.text = text
        XCTAssertNil(model.submit(system: .wgs84, preferred: .gcj02))
        request.succeed("迟到结果")
        await first.value
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(request.cancelled)
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results.first?.mapCoordinateSystem, expectedSystem)
        XCTAssertEqual(model.results.first?.remembersPreference, remembers)
        XCTAssertEqual(model.results.first?.coordinate.latitude, 22.5)
        XCTAssertEqual(model.results.first?.coordinate.longitude, 113.9)
        XCTAssertEqual(model.submittedQuery, text)
    }

    func testEditAwayAndBackDoesNotReviveOldIntent() async throws {
        let request = ControlledMapSearch()
        let model = MapSearchModel { _, _ in request }
        model.text = "原查询"
        let task = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await request.waitUntilStarted()
        model.text = "拼音组合输入"
        model.text = "原查询"
        request.succeed("原查询")
        await task.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.text, "原查询")
        XCTAssertNil(model.submittedQuery)
    }

    func testDismissalCancelsAndDoesNotPublish() async throws {
        let request = ControlledMapSearch()
        let model = MapSearchModel { _, _ in request }
        model.text = "A"
        let task = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
        await request.waitUntilStarted()
        model.dismissResults()
        request.succeed("迟到")
        await task.value
        XCTAssertEqual(model.text, "A")
        XCTAssertTrue(request.cancelled)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testOwnerCanDeinitializeWhileSearchIsPending() async throws {
        let request = ControlledMapSearch()
        var model: MapSearchModel? = MapSearchModel { _, _ in request }
        weak var weakModel = model
        model?.text = "A"
        let task = try XCTUnwrap(model?.submit(system: .wgs84, preferred: .wgs84))
        await request.waitUntilStarted()
        model = nil
        XCTAssertNil(weakModel)
        XCTAssertTrue(request.cancelled)
        request.succeed("迟到")
        await task.value
    }

    func testSuccessEmptyAndRealFailureFeedback() async throws {
        for outcome in [Result<[SearchLocationResult], Error>.success([ControlledMapSearch.result("结果")]),
                        .success([]), .failure(URLError(.notConnectedToInternet))] {
            let request = ControlledMapSearch()
            let model = MapSearchModel { _, _ in request }
            model.text = "测试"
            let task = try XCTUnwrap(model.submit(system: .wgs84, preferred: .wgs84))
            await request.waitUntilStarted()
            request.complete(outcome)
            await task.value
            XCTAssertFalse(model.isSearching)
            switch outcome {
            case .success(let results):
                XCTAssertEqual(model.results.map(\.name), results.map(\.name))
                XCTAssertEqual(model.error, results.isEmpty ? "没有找到相关地点" : "")
            case .failure(let error):
                XCTAssertEqual(model.error, error.localizedDescription)
            }
        }
    }

    func testCapturesTrimmedQueryAndCoordinateSystemWithoutRewritingInput() async throws {
        let request = ControlledMapSearch()
        var captured: (String, CoordinateConverter.MapCoordinateSystem)?
        let model = MapSearchModel { query, system in captured = (query, system); return request }
        model.text = "  中文测试  "
        let task = try XCTUnwrap(model.submit(system: .gcj02, preferred: .wgs84))
        await request.waitUntilStarted()
        XCTAssertEqual(captured?.0, "中文测试")
        XCTAssertEqual(captured?.1, .gcj02)
        XCTAssertEqual(model.text, "  中文测试  ")
        request.succeed("结果")
        await task.value
    }
}

final class ControlledMapSearch: MapSearchRequest {
    var cancelled = false
    @MainActor private var continuation: CheckedContinuation<[SearchLocationResult], Error>?
    @MainActor private var started: CheckedContinuation<Void, Never>?

    @MainActor
    func start() async throws -> [SearchLocationResult] {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func cancel() { cancelled = true }

    @MainActor
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    @MainActor
    func succeed(_ name: String) {
        complete(.success([Self.result(name)]))
    }

    @MainActor
    func fail(_ error: Error) { complete(.failure(error)) }

    @MainActor
    func complete(_ outcome: Result<[SearchLocationResult], Error>) {
        continuation?.resume(with: outcome)
        continuation = nil
    }

    static func result(_ name: String) -> SearchLocationResult {
        SearchLocationResult(name: name, subtitle: "测试地点", coordinate: .init(latitude: 22, longitude: 113),
                             mapCoordinateSystem: .wgs84)
    }
}
