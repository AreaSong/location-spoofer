import SwiftUI

/// 最近与收藏共享同一区域；切换只改变展示，不修改选点和收藏数据。
struct MapHomeSelectionChips<RecentChips: View, FavoriteChips: View, AllFavorites: View>: View {
    let hasRecents: Bool
    let favoritesEmpty: Bool
    let recentChips: RecentChips
    let favoriteChips: FavoriteChips
    let allFavoritesButton: AllFavorites
    let onClearRecents: () -> Void
    @State private var showsClearRecents = false
    @State private var showsFavorites = false

    init(
        hasRecents: Bool,
        favoritesEmpty: Bool,
        @ViewBuilder recentChips: () -> RecentChips,
        @ViewBuilder favoriteChips: () -> FavoriteChips,
        @ViewBuilder allFavoritesButton: () -> AllFavorites,
        onClearRecents: @escaping () -> Void = {}
    ) {
        self.hasRecents = hasRecents
        self.favoritesEmpty = favoritesEmpty
        self.recentChips = recentChips()
        self.favoriteChips = favoriteChips()
        self.allFavoritesButton = allFavoritesButton()
        self.onClearRecents = onClearRecents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                tab("最近", selected: !showsFavorites) { showsFavorites = false }
                tab("收藏", selected: showsFavorites) { showsFavorites = true }
                Spacer(minLength: 0)
                if showsFavorites {
                    allFavoritesButton
                        .frame(minHeight: 44)
                } else if hasRecents {
                    Button("清空") { showsClearRecents = true }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            if showsFavorites {
                if favoritesEmpty {
                    Text("收藏常用地点，下次可以直接选用。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { favoriteChips }
                    }
                }
            } else if hasRecents {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { recentChips }
                }
            } else {
                Text("搜索或点击地图后，选点会出现在这里。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("清空最近选点？", isPresented: $showsClearRecents, titleVisibility: .visible) {
            Button("清空", role: .destructive) { onClearRecents() }
            Button("取消", role: .cancel) {}
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(minWidth: 44, minHeight: 44)
            .overlay(alignment: .bottom) {
                if selected { Capsule().fill(Color.primary).frame(height: 2) }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
