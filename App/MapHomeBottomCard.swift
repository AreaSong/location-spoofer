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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HomeFittingScrollView(maxHeight: availableHeight - actionHeight - 32) {
                VStack(alignment: .leading, spacing: 6) {
                    locationHeader
                    statusRow
                    detailContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionRow
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(.thickMaterial)
                .overlay(alignment: .top) { routeProgressBar }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
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
