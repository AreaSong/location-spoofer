import SwiftUI

/// 关键控制固定在概览区，展开仅增加当前任务的工具，不改变按钮含义。
struct MapHomeBottomCard<SpotContent: View, RoutePanel: View, Caption: View>: View {
    let displayName: String
    let selectionStatus: String
    let spoofState: SpoofState
    let isFavoriteSelected: Bool
    let favoriteSaveDisabled: Bool
    let runtimeStatusText: String
    let runtimeStatusTone: StatusPill.Tone
    let showsRoute: Bool
    let routeChipSubtitle: String?
    let showsRouteProgress: Bool
    let primaryTitle: String
    let primaryAccessibilityLabel: String
    let primarySystemImage: String?
    let primaryColor: Color
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let secondaryDisabled: Bool
    let showsSpotHelp: Bool
    let expandedMaxHeight: CGFloat
    let availableHeight: CGFloat
    @Binding var isExpanded: Bool
    @ObservedObject var playbackClock: RoutePlaybackClock
    @ViewBuilder let spotContent: () -> SpotContent
    @ViewBuilder let routePanel: () -> RoutePanel
    @ViewBuilder let caption: () -> Caption
    let onShowSpot: () -> Void
    let onShowRoute: () -> Void
    let onHelp: () -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void
    let onPrimaryTap: () -> Void
    let onSecondaryTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detailHeight: CGFloat = 0
    @State private var actionHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize || availableHeight < 360 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        overview
                        if isExpanded { Divider(); detailContent }
                    }
                }
                .frame(maxHeight: max(60, availableHeight - actionHeight - 34))
                actionRow
            } else {
                overview
                actionRow
                if isExpanded { Divider(); expandedDetail }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .top) { routeProgressBar }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isExpanded)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 6) {
            modeRow
            locationHeader
            statusRow
        }
    }

    @ViewBuilder
    private var modeRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 4) { modeSwitcher; detailButton }
        } else {
            HStack(spacing: 12) { modeSwitcher; detailButton }
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            modeButton("定点", symbol: "mappin", selected: !showsRoute, action: onShowSpot)
            modeButton("路线", symbol: "point.topleft.down.curvedto.point.bottomright.up",
                       selected: showsRoute, action: onShowRoute)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.control))
    }

    private var detailButton: some View {
        Button { isExpanded.toggle() } label: {
            Label(isExpanded ? "收起" : "详情", systemImage: isExpanded ? "chevron.down" : "chevron.up")
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起详情" : "展开详情")
        .accessibilityIdentifier("home.details")
    }

    private func modeButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Group {
                    if typeSize.isAccessibilitySize {
                        Text(title)
                    } else {
                        Label(title, systemImage: symbol)
                    }
                }
                .font(.subheadline.weight(.semibold))
                if title == "路线", !showsRoute, let subtitle = routeChipSubtitle {
                    Text(subtitle).font(.caption2)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: AppRadius.inset)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(selected ? "home.mode.selected" : "home.mode.other")
    }

    private var locationHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(selectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                caption()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !showsRoute {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavoriteSelected ? "star.fill" : "star")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(isFavoriteSelected ? Color.orange : Color.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(favoriteSaveDisabled)
                .accessibilityLabel(isFavoriteSelected ? "取消选中收藏" : "收藏当前选点")
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Circle().fill(runtimeStatusTone.color).frame(width: 6, height: 6)
                    Text(runtimeStatusText).font(.caption)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开设置")
            Spacer(minLength: 0)
            if showsSpotHelp {
                Button(action: onHelp) {
                    Label("帮助", systemImage: "questionmark.circle")
                        .font(.caption)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actionRow: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { primaryButton; secondaryButton }
            } else {
                HStack(spacing: 10) { secondaryButton; primaryButton }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: HomeActionHeightKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(HomeActionHeightKey.self) { actionHeight = $0 }
    }

    private var primaryButton: some View {
        Button(action: onPrimaryTap) {
            HStack(spacing: 6) {
                if spoofState == .verifying, !showsRoute {
                    ProgressView().tint(.white)
                } else if let primarySystemImage {
                    Image(systemName: primarySystemImage)
                }
                Text(primaryTitle)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 8)
            .foregroundStyle(.white)
            .background(primaryColor.opacity(primaryDisabled ? 0.45 : 1),
                        in: RoundedRectangle(cornerRadius: AppRadius.control))
        }
        .buttonStyle(.plain)
        .disabled(primaryDisabled)
        .accessibilityLabel(primaryAccessibilityLabel)
        .accessibilityIdentifier("home.primary")
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if let secondaryTitle {
            Button(secondaryTitle, action: onSecondaryTap)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control))
                .buttonStyle(.plain)
                .disabled(secondaryDisabled)
                .accessibilityIdentifier("home.secondary")
        }
    }

    private var expandedDetail: some View {
        ScrollView {
            detailContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: HomeDetailHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .onPreferenceChange(HomeDetailHeightKey.self) { detailHeight = $0 }
        .frame(height: min(detailHeight > 0 ? detailHeight : expandedMaxHeight, expandedMaxHeight))
    }

    @ViewBuilder
    private var detailContent: some View {
        if showsRoute {
            routePanel()
        } else {
            spotContent()
        }
    }

    @ViewBuilder
    private var routeProgressBar: some View {
        if showsRouteProgress {
            GeometryReader { geometry in
                Rectangle().fill(Color.accentColor)
                    .frame(width: max(0, geometry.size.width * playbackClock.progress))
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }
}

private enum HomeDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private enum HomeActionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 48
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
