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
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomeInteractiveButtonStyle())
    }
}

/// 路线常用区：已存路线竖向平铺，采用紧凑卡片排版。
struct HomeRouteSavedList: View {
    let routes: [SavedRoute]
    let selectedID: UUID?
    let onSelect: (SavedRoute) -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            if routes.isEmpty {
                Text("还没有保存的路线。在地图上规划后点击保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(routes) { route in savedRow(route) }
                    }
                }
                .accessibilityIdentifier("home.route.saved")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已存路线")
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("已存路线")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            manageButton
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private var manageButton: some View {
        Button(action: onManage) {
            Text("管理")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomeInteractiveButtonStyle())
        .accessibilityLabel("管理与导入路线")
    }

    private func travelIcon(for mode: RouteTravelMode) -> String {
        switch mode {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    private func savedRow(_ route: SavedRoute) -> some View {
        let selected = selectedID == route.id
        return Button {
            Haptics.selection()
            onSelect(route)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: travelIcon(for: route.travelMode))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(route.name)
                    .font(.caption.weight(selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(RoutePlayback.formattedDistance(route.distanceMeters))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeInteractiveButtonStyle())
        .background(
            (selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 0.75)
        )
        .accessibilityLabel(selected ? "\(route.name)，\(route.travelMode.displayName)，已选中" : "\(route.name)，\(route.travelMode.displayName)")
    }
}
