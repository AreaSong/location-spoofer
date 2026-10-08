import SwiftUI

/// 摘要与参数在受限区域内滚动，执行按钮固定在底部。
struct MapHomeBottomCard<SpotContent: View, RoutePanel: View, Caption: View>: View {
    let displayName: String
    let selectionStatus: String
    let spoofState: SpoofState
    let isFavoriteSelected: Bool
    let favoriteSaveDisabled: Bool
    let runtimeStatusText: String
    let runtimeStatusTone: StatusPill.Tone
    let showsRoute: Bool
    let showsRouteProgress: Bool
    let primaryTitle: String
    let primaryAccessibilityLabel: String
    let primarySystemImage: String?
    let primaryColor: Color
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let secondaryDisabled: Bool
    let showsSpotHelp: Bool
    let availableHeight: CGFloat
    @ObservedObject var playbackClock: RoutePlaybackClock
    @ViewBuilder let spotContent: () -> SpotContent
    @ViewBuilder let routePanel: () -> RoutePanel
    @ViewBuilder let caption: () -> Caption
    let onHelp: () -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void
    let onPrimaryTap: () -> Void
    let onSecondaryTap: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var actionHeight: CGFloat = 48
    @State private var showsStatusDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HomeFittingScrollView(maxHeight: availableHeight - actionHeight - 32, fillsMaxHeight: true) {
                VStack(alignment: .leading, spacing: 6) {
                    locationHeader
                    detailContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionRow
        }
        .padding(12)
        .frame(height: availableHeight, alignment: .top)
        .overlay { statusDetailOverlay }
        .background {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(.thickMaterial)
                .overlay(alignment: .top) { routeProgressBar }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    private var locationHeader: some View {
        titleRow
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: HomeCardHeaderHeightKey.self, value: geometry.size.height)
                }
            }
    }

    @ViewBuilder
    private var titleRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 0) {
                    titleText
                    statusDetailButton
                }
                HStack(spacing: 8) {
                    runtimeStatusButton
                    if showsSpotHelp { helpButton }
                    if !showsRoute { favoriteButton }
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                titleText
                statusDetailButton
                Spacer(minLength: 8)
                runtimeStatusButton
                if showsSpotHelp { helpButton }
                if !showsRoute { favoriteButton }
            }
        }
    }

    private var titleText: some View {
        Text(displayName)
            .font(.headline)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            .truncationMode(.tail)
            .frame(minWidth: 0, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: HomeCardTitleFrameKey.self, value: geometry.frame(in: .global))
                }
            }
            .accessibilityIdentifier("home.cardTitle")
            .accessibilityValue(selectionStatus)
    }

    private var statusDetailButton: some View {
        Button {
            showsStatusDetail.toggle()
        } label: {
            Image(systemName: showsStatusDetail ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityLabel("查看说明")
        .accessibilityValue(selectionStatus)
        .accessibilityHint("显示当前选点或路线的说明")
        .accessibilityIdentifier("home.statusDetail")
    }

    @ViewBuilder
    private var statusDetailOverlay: some View {
        if showsStatusDetail {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { showsStatusDetail = false }
                    .accessibilityHidden(true)
                statusDetailPanel
                    .padding(8)
            }
            .accessibilityIdentifier("home.statusDetail.panel")
        }
    }

    private var statusDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("说明")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("完成") { showsStatusDetail = false }
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44)
            }
            Text(selectionStatus)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            caption()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var runtimeStatusButton: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 4) {
                Circle().fill(runtimeStatusTone.color).frame(width: 6, height: 6)
                Text(runtimeStatusText).font(.caption).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityHint("打开设置")
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: HomeRuntimeStatusFrameKey.self, value: geometry.frame(in: .global))
            }
        }
        .accessibilityIdentifier("home.runtimeStatus")
    }

    private var favoriteButton: some View {
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

    private var helpButton: some View {
        Button(action: onHelp) {
            Label("帮助", systemImage: "questionmark.circle")
                .font(.caption)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("帮助")
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
        .onPreferenceChange(HomeActionHeightKey.self) { if $0 > 0 { actionHeight = $0 } }
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

private enum HomeActionHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum HomeCardHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum HomeCardTitleFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

enum HomeRuntimeStatusFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
