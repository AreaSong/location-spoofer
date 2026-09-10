import SwiftUI

struct SavedRouteListView: View {
    @ObservedObject var store: SavedRouteStore
    var onSelect: (SavedRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editingRoute: SavedRoute?
    @State private var editName = ""

    var body: some View {
        List {
            if filteredRoutes.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredRoutes) { route in
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
            }
        }
        .navigationTitle("已存路线")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索名称")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
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

    private var filteredRoutes: [SavedRoute] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.routes }
        return store.routes.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var emptyText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "还没有保存的路线。设好起点和终点后点「保存」。"
            : "没有匹配的路线"
    }
}
