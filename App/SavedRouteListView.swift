import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SavedRouteListView: View {
    @ObservedObject var store: SavedRouteStore
    @ObservedObject var recentRoutes: RecentRouteStore
    @ObservedObject var routeImport: RouteImportCoordinator
    var isListPresented: () -> Bool
    var onSelect: (SavedRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editingRoute: SavedRoute?
    @State private var editName = ""
    @State private var pageID = UUID()
    @State private var fileSelection: RouteImportCoordinator.FileRequest?

    var body: some View {
        List {
            if routeImport.isBusy {
                Section {
                    ProgressView(routeImport.state == .cancelling ? "正在取消，等待处理结束…" : "正在导入路线…")
                    Button("取消导入", role: .cancel) { routeImport.cancel() }
                        .disabled(routeImport.state != .preparing)
                }
            }
            if !filteredRecent.isEmpty {
                Section("最近走过") {
                    ForEach(filteredRecent) { route in
                        Button {
                            routeImport.leavePage(pageID)
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
                        .disabled(routeImport.isBusy)
                    Button("从文件导入") {
                        guard isListPresented() else { return }
                        fileSelection = routeImport.beginFileSelection(pageID: pageID)
                    }
                    .disabled(routeImport.isBusy)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导入或导出路线")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { routeImport.leavePage(pageID); dismiss() }
            }
        }
        .onAppear {
            if isListPresented() { routeImport.enterPage(pageID) }
        }
        .sheet(item: $fileSelection) { request in
            RouteImportFilePicker(types: Self.importTypes) { result in
                importFile(result, request: request)
            }
        }
        .alert(routeImport.notice?.title ?? "路线", isPresented: Binding(
            get: { routeImport.notice != nil },
            set: { if !$0 { routeImport.notice = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(routeImport.notice?.message ?? "")
        }
        .alert("编辑路线名称", isPresented: Binding(
            get: { editingRoute != nil },
            set: { if !$0 { editingRoute = nil } }
        )) {
            TextField("名称", text: $editName)
            Button("保存") {
                if let route = editingRoute {
                    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    do { try store.rename(route.id, to: name.isEmpty ? route.name : name) }
                    catch { present("路线改名失败", error.localizedDescription) }
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
            routeImport.leavePage(pageID)
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
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    do { try store.delete(route) }
                    catch { present("路线删除失败", error.localizedDescription) }
                }
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

    private var pageAllowsImport: Bool {
        isListPresented() && routeImport.ownsPage(pageID)
    }

    private func importFromClipboard() {
        guard pageAllowsImport, !routeImport.isBusy else { return }
        // UIKit 读取仅在主 actor 捕获快照；空白检查及 UTF-8 转换在后台进行。
        startImport(.clipboard(UIPasteboard.general.string ?? ""))
    }

    private func importFile(_ result: Result<URL, Error>, request: RouteImportCoordinator.FileRequest) {
        guard request.pageID == pageID, pageAllowsImport,
              routeImport.acceptFileSelection(request) else { return }
        if fileSelection == request { fileSelection = nil }
        switch result {
        case .success(let url): startImport(.file(url))
        case .failure(let error):
            guard !RouteImportCoordinator.isCancellation(error) else { return }
            present("路线导入失败", error.localizedDescription)
        }
    }

    private func startImport(_ input: RouteImportPreparation.Input) {
        routeImport.start(input, pageID: pageID, isPageActive: { pageAllowsImport }) { prepared in
            store.importTransferred(prepared.routes)
        }
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.json, .xml]
        for ext in ["gpx", "kml", "kmz"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private func present(_ title: String, _ message: String) {
        routeImport.report(title, message)
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
            ? "还没有保存的路线。设好起点和终点后点「保存」，或从文件导入 GPX / KML。"
            : "没有匹配的路线"
    }
}
