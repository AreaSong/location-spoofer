import Combine
import Foundation

@MainActor
final class FavoriteImportCoordinator: ObservableObject {
    enum State: Equatable { case idle, preparing, cancelling }
    struct Notice: Equatable {
        let title: String
        let message: String
    }

    @Published private(set) var state = State.idle
    @Published var notice: Notice?
    // @Published 在 willSet 同步通知；资格判断只读取内部阶段及操作身份。
    private var phase = State.idle
    private var pendingNotice: Notice?
    private var isPublishingNotice = false
    private var pageID: UUID?
    private var operationID: UUID?
    private var worker: Task<FavoriteTransfer.Prepared, Error>?
    private var completion: Task<Void, Never>?
    var isBusy: Bool { operationID != nil }

    deinit { worker?.cancel(); completion?.cancel() }

    @discardableResult
    func start(
        _ input: FavoriteImportPreparation.Input,
        isPageActive: @escaping @MainActor () -> Bool,
        prepare: @escaping @Sendable (FavoriteImportPreparation.Input) async throws -> FavoriteTransfer.Prepared = {
            try FavoriteImportPreparation.prepare($0)
        },
        commit: @escaping @MainActor (FavoriteTransfer.Prepared) -> FavoriteTransfer.MergeResult
    ) -> Bool {
        guard operationID == nil, isPageActive() else { return false }
        let id = UUID()
        operationID = id
        phase = .preparing
        publishNotice(nil)
        publishState()
        // 两处通知均可能取消或结束页面，尚未启动时直接释放本轮占位。
        guard operationID == id, phase == .preparing, isPageActive() else {
            finish(id)
            return true
        }
        // detached 明确脱离主 actor；闭包仅获得输入快照及准备依赖。
        let work = Task.detached(priority: .userInitiated) { try await prepare(input) }
        worker = work
        completion = Task { [weak self] in
            let result = await work.result
            guard let self, self.operationID == id else { return }
            defer { self.finish(id) }
            guard self.phase == .preparing, !work.isCancelled, isPageActive() else { return }
            switch result {
            case .success(let prepared):
                // 此处至 commit 返回没有让出点。取消不回滚已经开始的同步提交。
                let merged = commit(prepared)
                guard self.operationID == id, self.phase == .preparing, isPageActive() else { return }
                self.publishNotice(Notice(title: "收藏已导入", message:
                    "新增 \(merged.added) 个，更新 \(merged.updated) 个，跳过重复 \(merged.skippedDuplicates) 个，超出上限 \(merged.skippedOverLimit) 个"))
            case .failure(let error):
                if !(error is CancellationError) { self.report(error.localizedDescription) }
            }
        }
        return true
    }

    func cancel() {
        guard operationID != nil, phase != .cancelling else {
            publishNotice(nil)
            return
        }
        phase = .cancelling
        worker?.cancel()
        publishNotice(nil)
        publishState()
        // 保留槽位直到旧工作真正返回，防止重复取消/重入堆积不可中断读取。
    }

    func enterPage(_ id: UUID) {
        guard pageID != id else { return }
        cancel()
        pageID = id
    }

    func ownsPage(_ id: UUID) -> Bool { pageID == id }

    func leavePage() {
        pageID = nil
        cancel()
    }

    func report(_ message: String) {
        publishNotice(Notice(title: "收藏导入失败", message: message))
    }

    func waitForCompletion() async { await completion?.value }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        worker = nil
        completion = nil
        operationID = nil
        phase = .idle
        publishState()
    }

    private func publishState() {
        // 内层取消或下一轮启动会改变 phase；外层 willSet 返回后修正过期赋值。
        while state != phase { state = phase }
    }

    private func publishNotice(_ value: Notice?) {
        pendingNotice = value
        guard !isPublishingNotice else { return }
        isPublishingNotice = true
        defer { isPublishingNotice = false }
        // 成功/失败提示的同步订阅者也能取消。合并重入写入，避免旧提示复活。
        while notice != pendingNotice { notice = pendingNotice }
    }
}
