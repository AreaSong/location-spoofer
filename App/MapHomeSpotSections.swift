import SwiftUI

/// 定点卡上、走路仍占着定位时的返回入口。一行按钮，避免挡住常用控制。
struct RunningRouteSpotNotice: View {
    let isPaused: Bool
    let isWaiting: Bool
    let onReturnToRoute: () -> Void

    var body: some View {
        Button(action: onReturnToRoute) {
            Label(title, systemImage: "figure.walk")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28)
                .padding(.horizontal, 12)
        }
        .buttonStyle(PrimaryActionStyle(tint: .orange, compact: true))
        .accessibilityLabel("回到走路")
        .accessibilityHint(detail)
    }

    private var title: String {
        if isWaiting { return "正在开启走路" }
        if isPaused { return "走路已暂停" }
        return "回到走路"
    }

    private var detail: String {
        if isWaiting { return "定位马上会沿路线更新。回到走路可查看进度。" }
        if isPaused { return "定位暂时停在当前点。回到走路可继续或结束这次走路。" }
        return "定位会继续沿路线更新。回到走路可改路线或暂停。"
    }
}

/// 定点卡片展开区的最近选点和收藏两行。
struct MapHomeSelectionChips<RecentChips: View, FavoriteChips: View, AllFavorites: View>: View {
    let hasRecents: Bool
    let favoritesEmpty: Bool
    let recentChips: RecentChips
    let favoriteChips: FavoriteChips
    let allFavoritesButton: AllFavorites
    let onClearRecents: () -> Void
    @State private var showsClearRecents = false

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
            if hasRecents {
                HStack(spacing: 8) {
                    Text("最近")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button("清空") { showsClearRecents = true }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            recentChips
                        }
                        .padding(.vertical, 2)
                    }
                }
                .confirmationDialog("清空最近选点？", isPresented: $showsClearRecents, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { onClearRecents() }
                    Button("取消", role: .cancel) {}
                }
            }
            if favoritesEmpty {
                HStack {
                    Text("搜索或点击地图选点后，保存为收藏。").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    allFavoritesButton
                }
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { favoriteChips }.padding(.vertical, 2)
                    }
                    allFavoritesButton
                }
            }
        }
    }
}
