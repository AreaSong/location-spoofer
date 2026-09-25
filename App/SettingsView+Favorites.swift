import SwiftUI
import UIKit

extension SettingsView {
    @ViewBuilder
    var favoriteBackupSection: some View {
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
            Button {
                showFavoriteImporter = true
            } label: {
                Label("从文件导入", systemImage: "folder")
            }
        }
    }

    /// 返回要写入剪贴板的备份文本；失败时弹出错误并返回 nil，按钮不切到“已复制”。
    func exportFavoritesToClipboard() -> String? {
        do {
            let data = try favorites.exportTransferred()
            guard let text = String(data: data, encoding: .utf8) else {
                presentFavoriteTransferError("无法编码收藏备份")
                return nil
            }
            RuntimeLogger.info("APP", "收藏", "已导出收藏到剪贴板", details: [
                "数量": String(favorites.favorites.count)
            ])
            return text
        } catch {
            presentFavoriteTransferError(error.localizedDescription)
            return nil
        }
    }

    func shareFavoritesFile() {
        do {
            let data = try favorites.exportTransferred()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("location-spoofer-favorites.json")
            try data.write(to: url, options: .atomic)
            ShareSheetPresenter.presentFile(at: url)
        } catch {
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    func importFavoritesFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentFavoriteTransferError("剪贴板里没有收藏备份")
            return
        }
        importFavorites(from: Data(text.utf8))
    }

    func importFavorites(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                importFavorites(from: try Data(contentsOf: url))
            } catch {
                presentFavoriteTransferError(error.localizedDescription)
            }
        case .failure(let error):
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    func importFavorites(from data: Data) {
        do {
            let incoming = try FavoriteTransfer.decode(data)
            let result = favorites.importTransferred(incoming)
            favoriteTransferTitle = "收藏已导入"
            favoriteTransferMessage = "新增 \(result.added) 个，更新 \(result.updated) 个，跳过重复 \(result.skippedDuplicates) 个，超出上限 \(result.skippedOverLimit) 个"
            RuntimeLogger.info("APP", "收藏", "已合并导入收藏", details: [
                "新增": String(result.added),
                "更新": String(result.updated)
            ])
        } catch {
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    func presentFavoriteTransferError(_ message: String) {
        favoriteTransferTitle = "收藏导入失败"
        favoriteTransferMessage = message
    }

}
