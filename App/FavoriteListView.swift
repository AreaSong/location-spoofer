import SwiftUI
import CoreLocation

struct FavoriteListView: View {
    @ObservedObject var favorites: FavoriteLocationStore
    var onSelect: (FavoriteLocation) -> Void
    var onRename: (FavoriteLocation, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editingFavorite: FavoriteLocation?
    @State private var editName = ""

    var body: some View {
        List {
            if filteredFavorites.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredFavorites) { favorite in
                    Button {
                        onSelect(favorite)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(favorite.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(coordinateText(favorite.coordinatePair.gcj02, label: "GCJ-02"))
                            Text(coordinateText(favorite.coordinatePair.wgs84, label: "WGS-84"))
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            favorites.delete(favorite)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editingFavorite = favorite
                            editName = favorite.name
                        } label: {
                            Label("改名", systemImage: "pencil")
                        }
                    }
                }
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索名称")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    ForEach(FavoriteLocationStore.SortOrder.allCases, id: \.self) { order in
                        Button {
                            favorites.setSortOrder(order)
                        } label: {
                            if favorites.sortOrder == order {
                                Label(order.title, systemImage: "checkmark")
                            } else {
                                Text(order.title)
                            }
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .alert("编辑收藏名称", isPresented: Binding(
            get: { editingFavorite != nil },
            set: { if !$0 { editingFavorite = nil } }
        )) {
            TextField("名称", text: $editName)
            Button("保存") {
                if let favorite = editingFavorite {
                    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onRename(favorite, name.isEmpty ? favorite.name : name)
                }
                editingFavorite = nil
            }
            Button("取消", role: .cancel) { editingFavorite = nil }
        } message: {
            Text("修改收藏地点名称")
        }
    }

    private var filteredFavorites: [FavoriteLocation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return favorites.displayedFavorites }
        return favorites.displayedFavorites.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var emptyText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "还没有收藏。在地图上选点后点星标保存。"
            : "没有匹配的收藏"
    }

    private func coordinateText(_ value: CoordinatePair.Value, label: String) -> String {
        String(format: "%@: %.6f, %.6f", label, value.latitude, value.longitude)
    }
}
