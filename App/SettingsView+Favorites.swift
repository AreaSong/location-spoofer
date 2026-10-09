import SwiftUI
import UIKit

/// 收藏数据备份与导入设置组件
struct FavoriteBackupSection: View {
    @ObservedObject var favorites: FavoriteLocationStore
    @ObservedObject var favoriteImport: FavoriteImportCoordinator
    var isAllowedToImport: () -> Bool
    var onRequestFileImport: () -> Void

    var body: some View {
        Section("收藏") {
            Text("共 \(favorites.favorites.count) 个地点，最多 \(FavoriteLocationStore.limit) 个。导入时相同国际坐标会更新名称；同一份备份里的重复点只保留最后一条，超出上限的新地点会跳过。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            CopyButton("导出到剪贴板", copiedTitle: "已复制收藏备份", value: exportFavoritesToClipboard)
                .disabled(favorites.favorites.isEmpty)

            Button(action: shareFavoritesFile) {
                Label("分享备份文件", systemImage: "square.and.arrow.up")
            }
            .disabled(favorites.favorites.isEmpty)

            Button(action: importFavoritesFromClipboard) {
                Label("从剪贴板导入", systemImage: "clipboard")
            }
            .disabled(favoriteImport.isBusy)

            Button {
                guard !favoriteImport.isBusy else { return }
                onRequestFileImport()
            } label: {
                Label("从文件导入", systemImage: "folder")
            }
            .disabled(favoriteImport.isBusy)

            if favoriteImport.isBusy {
                ProgressView(favoriteImport.state == .cancelling ? "正在取消，等待读取结束…" : "正在导入收藏…")
                Button("取消导入", role: .cancel) { favoriteImport.cancel() }
                    .disabled(favoriteImport.state == .cancelling)
            }
        }
    }

    // MARK: - Actions

    private func exportFavoritesToClipboard() -> String? {
        do {
            let data = try favorites.exportTransferred()
            guard let text = String(data: data, encoding: .utf8) else {
                favoriteImport.report("无法编码收藏备份")
                return nil
            }
            RuntimeLogger.info("APP", "收藏", "已导出收藏到剪贴板", details: [
                "数量": String(favorites.favorites.count)
            ])
            return text
        } catch {
            favoriteImport.report(error.localizedDescription)
            return nil
        }
    }

    private func shareFavoritesFile() {
        do {
            let data = try favorites.exportTransferred()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("location-spoofer-favorites.json")
            try data.write(to: url, options: .atomic)
            ShareSheetPresenter.presentFile(at: url)
        } catch {
            favoriteImport.report(error.localizedDescription)
        }
    }

    private func importFavoritesFromClipboard() {
        guard !favoriteImport.isBusy, isAllowedToImport() else { return }
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            favoriteImport.report("剪贴板里没有收藏备份")
            return
        }
        favoriteImport.start(.clipboard(text), isPageActive: isAllowedToImport) { prepared in
            let result = favorites.importPrepared(prepared)
            RuntimeLogger.info("APP", "收藏", "已合并导入收藏", details: [
                "新增": String(result.added), "更新": String(result.updated)
            ])
            return result
        }
    }
}

// MARK: - SettingsView Extension Wrapper

extension SettingsView {
    @ViewBuilder
    var favoriteBackupSection: some View {
        FavoriteBackupSection(
            favorites: favorites,
            favoriteImport: favoriteImport,
            isAllowedToImport: { favoritePageAllowsImport },
            onRequestFileImport: { showFavoriteImporter = true }
        )
    }

    var favoritePageAllowsImport: Bool {
        isSettingsPresented() && !showingBugReport && favoriteImport.ownsPage(favoritePageID)
    }

    func importFavorites(from result: Result<URL, Error>) {
        guard favoritePageAllowsImport, !favoriteImport.isBusy else { return }
        switch result {
        case .success(let url):
            startFavoriteImport(.file(url))
        case .failure(let error):
            let cocoa = error as NSError
            guard !(error is CancellationError),
                  !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError) else { return }
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    func startFavoriteImport(_ input: FavoriteImportPreparation.Input) {
        favoriteImport.start(input, isPageActive: { favoritePageAllowsImport }) { prepared in
            let result = favorites.importPrepared(prepared)
            RuntimeLogger.info("APP", "收藏", "已合并导入收藏", details: [
                "新增": String(result.added), "更新": String(result.updated)
            ])
            return result
        }
    }

    func presentFavoriteTransferError(_ message: String) {
        favoriteImport.report(message)
    }
}
