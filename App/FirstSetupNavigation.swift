import SwiftUI

/// 页面内的步骤与隔离预览反馈；真实环境检测仍由 SetupCoordinator 负责。
@MainActor
final class FirstSetupNavigation: ObservableObject {
    typealias Wait = @MainActor (UInt64) async throws -> Void

    @Published var step: SetupStep {
        // 即使重新选择同一步骤，也代表新的导航意图；不能仅比较枚举值。
        willSet { invalidatePreview() }
    }
    @Published private(set) var isPreviewVerifying = false
    @Published private(set) var previewSucceeded = false
    private let wait: Wait
    private let onComplete: () -> Void
    private var previewTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isActive = false
    private var hasCompleted = false

    init(step: SetupStep, wait: @escaping Wait = { try await Task.sleep(nanoseconds: $0) },
         onComplete: @escaping () -> Void) {
        self.step = step
        self.wait = wait
        self.onComplete = onComplete
    }

    deinit { previewTask?.cancel() }

    func appear() {
        guard !isActive else { return }
        isActive = true
        hasCompleted = false
    }

    func disappear() {
        isActive = false
        invalidatePreview()
    }

    func returnToPreviousStep() {
        switch step {
        case .mode: break
        case .proxy, .thirdPartyClient, .developerTunnel: step = .mode
        case .cert: step = .proxy
        case .thirdPartyImport: step = .thirdPartyClient
        }
    }

    @discardableResult
    func startPreviewCheck() -> Task<Void, Never>? {
        guard isActive, !hasCompleted, !isPreviewVerifying,
              [.proxy, .cert, .thirdPartyImport].contains(step) else { return nil }
        invalidatePreview()
        let operation = generation
        isPreviewVerifying = true
        let nextStep: SetupStep? = step == .proxy ? .cert : nil
        // 等待期间不强持有页面；收尾也只能清理自己所属的操作。
        let task = Task { @MainActor [weak self, wait] in
            defer { self?.finishPreviewTask(operation) }
            do {
                try await wait(350_000_000)
                guard self?.isCurrent(operation) == true else { return }
                self?.previewSucceeded = true
                self?.isPreviewVerifying = false
                try await wait(450_000_000)
                guard self?.isCurrent(operation) == true else { return }
                if let nextStep { self?.step = nextStep } else { self?.completePreview() }
            } catch {
                // 取消或等待失败均终止本轮，不再执行推进。
            }
        }
        previewTask = task
        return task
    }

    func completePreview() {
        guard isActive, !hasCompleted,
              [.cert, .thirdPartyImport, .developerTunnel].contains(step) else { return }
        hasCompleted = true
        invalidatePreview()
        onComplete()
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        isActive && !hasCompleted && generation == operation && !Task.isCancelled
    }

    private func invalidatePreview() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        isPreviewVerifying = false
        previewSucceeded = false
    }

    private func finishPreviewTask(_ operation: UInt64) {
        guard generation == operation else { return }
        previewTask = nil
        isPreviewVerifying = false
        previewSucceeded = false
    }
}
