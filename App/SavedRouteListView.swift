import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SavedRouteListView: View {
    @ObservedObject var store: SavedRouteStore
    @ObservedObject var recentRoutes: RecentRouteStore
    var onSelect: (SavedRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editingRoute: SavedRoute?
    @State private var editName = ""
    @State private var showsImporter = false
    @State private var transferTitle = ""
    @State private var transferMessage = ""
    @State private var showsTransferAlert = false

    var body: some View {
        List {
            if !filteredRecent.isEmpty {
                Section("最近走过") {
                    ForEach(filteredRecent) { route in
                        Button {
                            onSelect(route.savedRoute())
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("最近走过 · \(route.travelMode.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            Section("已存路线") {
                if filteredRoutes.isEmpty {
                    Text(emptyText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRoutes) { route in
                        routeRow(route)
                    }
                }
            }
        }
        .navigationTitle("路线")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索名称")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button("导出到剪贴板") { exportToClipboard() }
                        .disabled(store.routes.isEmpty)
                    Button("分享备份文件") { shareFile() }
                        .disabled(store.routes.isEmpty)
                    Button("从剪贴板导入") { importFromClipboard() }
                    Button("从文件导入") { showsImporter = true }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导入或导出路线")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            importFile(result)
        }
        .alert(transferTitle, isPresented: $showsTransferAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(transferMessage)
        }
        .alert("编辑路线名称", isPresented: Binding(
            get: { editingRoute != nil },
            set: { if !$0 { editingRoute = nil } }
        )) {
            TextField("名称", text: $editName)
            Button("保存") {
                if let route = editingRoute {
                    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.rename(route.id, to: name.isEmpty ? route.name : name)
                }
                editingRoute = nil
            }
            Button("取消", role: .cancel) { editingRoute = nil }
        } message: {
            Text("修改已保存路线的名称")
        }
    }

    private func routeRow(_ route: SavedRoute) -> some View {
        Button {
            onSelect(route)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(route.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(route.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.delete(route)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editingRoute = route
                editName = route.name
            } label: {
                Label("改名", systemImage: "pencil")
            }
        }
    }

    private func exportToClipboard() {
        do {
            let data = try store.exportTransferred()
            guard let text = String(data: data, encoding: .utf8) else {
                present("路线导出失败", "无法编码路线备份")
                return
            }
            UIPasteboard.general.string = text
            present("路线已导出", "已复制 \(store.routes.count) 条路线")
        } catch {
            present("路线导出失败", error.localizedDescription)
        }
    }

    private func shareFile() {
        do {
            let data = try store.exportTransferred()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("location-spoofer-routes.json")
            try data.write(to: url, options: .atomic)
            ShareSheetPresenter.presentFile(at: url)
        } catch {
            present("路线导出失败", error.localizedDescription)
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            present("路线导入失败", "剪贴板里没有路线备份")
            return
        }
        importRoutes(from: Data(text.utf8))
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                importRoutes(from: try Data(contentsOf: url))
            } catch {
                present("路线导入失败", error.localizedDescription)
            }
        case .failure(let error):
            present("路线导入失败", error.localizedDescription)
        }
    }

    private func importRoutes(from data: Data) {
        do {
            let incoming = try RouteTransfer.decode(data)
            let result = store.importTransferred(incoming)
            present(
                "路线已导入",
                "新增 \(result.added) 条，更新 \(result.updated) 条，超出上限 \(result.skippedOverLimit) 条"
            )
        } catch {
            present("路线导入失败", error.localizedDescription)
        }
    }

    private func present(_ title: String, _ message: String) {
        transferTitle = title
        transferMessage = message
        showsTransferAlert = true
    }

    private var filteredRoutes: [SavedRoute] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.routes }
        return store.routes.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var filteredRecent: [RecentRoute] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recentRoutes.routes }
        return recentRoutes.routes.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var emptyText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "还没有保存的路线。设好起点和终点后点「保存」。"
            : "没有匹配的路线"
    }
}
