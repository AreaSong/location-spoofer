import Combine
import Foundation

@MainActor
final class FavoriteImportCoordinator: ObservableObject {
    enum State: Equatable { case idle, preparing, cancelling }
    struct Notice {
        let title: String
        let message: String
    }

    @Published private(set) var state = State.idle
    @Published var notice: Notice?
    private var pageID: UUID?
    private var operationID: UUID?
    private var worker: Task<FavoriteTransfer.Prepared, Error>?
    private var completion: Task<Void, Never>?
    var isBusy: Bool { state != .idle }

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
        guard worker == nil, isPageActive() else { return false }
        let id = UUID()
        operationID = id
        notice = nil
        state = .preparing
        // detached 明确脱离主 actor；闭包仅获得输入快照及准备依赖。
        let work = Task.detached(priority: .userInitiated) { try await prepare(input) }
        worker = work
        completion = Task { [weak self] in
            let result = await work.result
            guard let self, self.operationID == id else { return }
            defer { self.finish(id) }
            guard self.state == .preparing, !work.isCancelled, isPageActive() else { return }
            switch result {
            case .success(let prepared):
                // 此处至 commit 返回没有让出点。取消不回滚已经开始的同步提交。
                let merged = commit(prepared)
                guard self.operationID == id, self.state == .preparing, isPageActive() else { return }
                self.notice = Notice(title: "收藏已导入", message:
                    "新增 \(merged.added) 个，更新 \(merged.updated) 个，跳过重复 \(merged.skippedDuplicates) 个，超出上限 \(merged.skippedOverLimit) 个")
            case .failure(let error):
                if !(error is CancellationError) { self.report(error.localizedDescription) }
            }
        }
        return true
    }

    func cancel() {
        notice = nil
        guard worker != nil else { return }
        state = .cancelling
        worker?.cancel()
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
        notice = Notice(title: "收藏导入失败", message: message)
    }

    func waitForCompletion() async { await completion?.value }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        worker = nil
        completion = nil
        operationID = nil
        state = .idle
    }
}
