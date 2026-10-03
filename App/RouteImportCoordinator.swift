import Combine
import Foundation

/// 列表宿主持有，跨列表重建保留在途槽位；页面仅持有本次展示身份。
@MainActor
final class RouteImportCoordinator: ObservableObject {
    enum State: Equatable { case idle, preparing, cancelling, committing }
    struct Notice {
        let title: String
        let message: String
    }
    struct FileRequest: Equatable, Identifiable {
        let pageID: UUID
        let id = UUID()
    }

    @Published private(set) var state = State.idle
    @Published var notice: Notice?
    // 发布属性的 willSet 可同步重入；内部状态和槽位才是决策来源。
    private var phase = State.idle
    private var hasStartedCommit = false
    private var pageID: UUID?
    private var fileRequest: FileRequest?
    private var operationID: UUID?
    private var worker: Task<RouteImportPreparation.Prepared, Error>?
    private var completion: Task<Void, Never>?
    var isBusy: Bool { operationID != nil }

    deinit { worker?.cancel(); completion?.cancel() }

    @discardableResult
    func start(
        _ input: RouteImportPreparation.Input,
        pageID: UUID,
        isPageActive: @escaping @MainActor () -> Bool,
        prepare: @escaping @Sendable (RouteImportPreparation.Input) async throws -> RouteImportPreparation.Prepared = {
            try RouteImportPreparation.prepare($0)
        },
        commit: @escaping @MainActor (RouteImportPreparation.Prepared) -> RouteTransfer.MergeResult
    ) -> Bool {
        guard operationID == nil, ownsPage(pageID), isPageActive() else { return false }
        let id = UUID()
        operationID = id
        phase = .preparing
        let work = Task.detached(priority: .userInitiated) { try await prepare(input) }
        worker = work
        completion = Task { [weak self] in
            let result = await work.result
            guard let self, self.operationID == id else { return }
            defer { self.finish(id) }
            guard self.phase == .preparing, !work.isCancelled,
                  self.ownsPage(pageID), isPageActive() else { return }
            switch result {
            case .success(let prepared):
                self.phase = .committing
                self.publishState()
                // 发布可同步重入；最后一次发布后重核全部资格，再进入同步提交。
                guard self.operationID == id, self.phase == .committing, !work.isCancelled,
                      self.ownsPage(pageID), isPageActive() else { return }
                self.hasStartedCommit = true
                let merged = commit(prepared)
                guard self.operationID == id, self.ownsPage(pageID), isPageActive() else { return }
                self.notice = Notice(title: merged.title, message: merged.message)
            case .failure(let error):
                if !Self.isCancellation(error) { self.report("路线导入失败", error.localizedDescription) }
            }
        }
        notice = nil
        publishState()
        return true
    }

    func cancel() {
        // 同步提交中没有逐条取消或回滚语义，计数必须反映已发生的写入。
        guard !hasStartedCommit else { return }
        if worker != nil {
            phase = .cancelling
            worker?.cancel()
        }
        notice = nil
        publishState()
        // 不可中断读取真实收尾前不释放槽位，重进页面也不能堆积任务。
    }

    func enterPage(_ id: UUID) {
        guard pageID != id else { return }
        cancel()
        fileRequest = nil
        pageID = id
    }

    func ownsPage(_ id: UUID) -> Bool { pageID == id }

    func leavePage(_ id: UUID? = nil) {
        if let id, !ownsPage(id) { return }
        pageID = nil
        fileRequest = nil
        cancel()
        notice = nil
    }

    func beginFileSelection(pageID: UUID) -> FileRequest? {
        guard ownsPage(pageID), !isBusy else { return nil }
        // UIKit 可能先关闭 sheet 再交付文件。保留旧令牌至回调/退出/下一次选择，
        // 新选择替换令牌，也允许交互式关闭（无选中文件）后立即重试。
        let request = FileRequest(pageID: pageID)
        fileRequest = request
        return request
    }

    func acceptFileSelection(_ request: FileRequest) -> Bool {
        guard fileRequest == request, ownsPage(request.pageID) else { return false }
        fileRequest = nil
        return !isBusy
    }

    static func isCancellation(_ error: Error) -> Bool {
        let cocoa = error as NSError
        return error is CancellationError
            || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError)
    }

    func report(_ title: String, _ message: String) { notice = Notice(title: title, message: message) }
    func waitForCompletion() async { await completion?.value }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        worker = nil
        completion = nil
        operationID = nil
        hasStartedCommit = false
        phase = .idle
        publishState()
    }

    private func publishState() {
        // 若订阅者在 willSet 里取消，外层赋值不能把 UI 留在过期的 preparing 状态。
        while state != phase { state = phase }
    }
}
