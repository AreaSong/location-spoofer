import XCTest
@testable import PaopaoLocationSpoofer

final class RuntimeLogStoreTests: XCTestCase {
    func testRetentionCutoffIsExactlyThreeDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            RuntimeLogStore.retentionCutoff(now: now),
            now.addingTimeInterval(-3 * 24 * 60 * 60)
        )
    }

    func testRetentionKeepsCutoffAndNewerEntriesOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = RuntimeLogStore.retentionCutoff(now: now)
        let expired = RuntimeLogEntry(timestamp: cutoff.addingTimeInterval(-0.001), source: "APP", level: .info, category: "Test", message: "expired")
        let boundary = RuntimeLogEntry(timestamp: cutoff, source: "APP", level: .info, category: "Test", message: "boundary")
        let recent = RuntimeLogEntry(timestamp: now, source: "CORE", level: .warning, category: "Proxy", message: "recent")

        XCTAssertEqual(
            RuntimeLogStore.retainedEntries([expired, boundary, recent], now: now),
            [boundary, recent]
        )
    }

    func testAsyncAppendsAreVisibleInOrderToNextLoad() {
        let category = "AsyncAppend-\(UUID().uuidString)"
        let messages = (0..<40).map { "entry-\($0)" }

        for message in messages {
            RuntimeLogStore.append(RuntimeLogEntry(source: "TEST", level: .info, category: category, message: message))
        }
        // 写盘在后台队列；读取排在已提交写入之后，不能漏读或乱序。
        let loaded = RuntimeLogStore.loadAll(limit: 100_000)
            .filter { $0.category == category }
            .map(\.message)

        XCTAssertEqual(loaded, messages)
    }

    func testAppendFromBackgroundThreadsDoesNotLoseEntries() {
        let category = "ConcurrentAppend-\(UUID().uuidString)"
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            RuntimeLogStore.append(RuntimeLogEntry(source: "TEST", level: .info, category: category, message: "entry-\(index)"))
        }

        let loaded = RuntimeLogStore.loadAll(limit: 100_000).filter { $0.category == category }

        XCTAssertEqual(Set(loaded.map(\.message)), Set((0..<30).map { "entry-\($0)" }))
    }

    func testErrorEntriesAreDurableBeforeAppendReturns() throws {
        let category = "SyncError-\(UUID().uuidString)"
        let entry = RuntimeLogEntry(source: "TEST", level: .error, category: category, message: "fatal")

        RuntimeLogStore.append(entry)

        // 不经 loadAll 的队列排序，直接读文件：error 必须在 append 返回前已写入磁盘。
        let directory = AppGroup.containerURL.appendingPathComponent("RuntimeLogs", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains(category))
    }
}
