import SwiftUI

/// 定点常用入口：最近与收藏各占一行，左右滑动，不把功能区撑高。
struct HomeSpotSwipeLanes<RecentBars: View, FavoriteBars: View>: View {
    let hasRecents: Bool
    let favoritesEmpty: Bool
    let recentBars: RecentBars
    let favoriteBars: FavoriteBars
    let onClearRecents: () -> Void
    let onManageFavorites: () -> Void
    @State private var showsClearRecents = false

    init(
        hasRecents: Bool,
        favoritesEmpty: Bool,
        @ViewBuilder recentBars: () -> RecentBars,
        @ViewBuilder favoriteBars: () -> FavoriteBars,
        onClearRecents: @escaping () -> Void,
        onManageFavorites: @escaping () -> Void
    ) {
        self.hasRecents = hasRecents
        self.favoritesEmpty = favoritesEmpty
        self.recentBars = recentBars()
        self.favoriteBars = favoriteBars()
        self.onClearRecents = onClearRecents
        self.onManageFavorites = onManageFavorites
    }

    var body: some View {
        VStack(spacing: 6) {
            lane(
                title: "最近",
                identifier: "home.spot.recents",
                trailingTitle: hasRecents ? "清空" : nil,
                trailingAction: { showsClearRecents = true }
            ) {
                if hasRecents {
                    recentBars
                } else {
                    emptyCaption("搜索或点击地图后会出现在这里")
                }
            }
            lane(
                title: "收藏",
                identifier: "home.spot.favorites",
                trailingTitle: "管理",
                trailingAction: onManageFavorites
            ) {
                if favoritesEmpty {
                    emptyCaption("收藏常用地点，下次可以直接选用。")
                } else {
                    favoriteBars
                }
            }
        }
        .confirmationDialog("清空最近选点？", isPresented: $showsClearRecents, titleVisibility: .visible) {
            Button("清空", role: .destructive, action: onClearRecents)
            Button("取消", role: .cancel) {}
        }
    }

    private func lane<Content: View>(
        title: String,
        identifier: String,
        trailingTitle: String?,
        trailingAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { content() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
            if let trailingTitle {
                laneAction(trailingTitle, action: trailingAction)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func emptyCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
    }

    private func laneAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.inset))
            .buttonStyle(.plain)
    }
}
