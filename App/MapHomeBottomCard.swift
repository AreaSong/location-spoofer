import SwiftUI

/// 标题、参数、主按钮分区固定；功能区不滚动，避免打开子功能时整块上下挪动。
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
    var viaTitle: String? = nil
    var viaDisabled: Bool = false
    var onViaTap: () -> Void = {}
    var onOpenSaved: (() -> Void)? = nil
    var isRouteActive: Bool = false
    var onSelectMode: ((Bool) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsStatusDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            pullHandle
            locationHeader
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
            actionRow
        }
        .padding(AppLayout.homeFunctionCardPadding)
        .frame(height: availableHeight, alignment: .top)
        .overlay(alignment: .topLeading) { statusDetailTip }
        .task(id: showsStatusDetail) {
            guard showsStatusDetail else { return }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            showsStatusDetail = false
        }
        .background {
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(.thickMaterial)
                .overlay(alignment: .top) { routeProgressBar }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    private var pullHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.secondary.opacity(0.24))
                .frame(width: 36, height: 4)
            Spacer()
        }
        .padding(.top, -2)
        .padding(.bottom, -2)
        .accessibilityHidden(true)
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
                HStack(alignment: .center, spacing: 6) {
                    if onSelectMode != nil {
                        modeSegmentControl
                            .layoutPriority(3)
                    } else {
                        titleText
                    }
                    if !showsRoute {
                        statusDetailButton
                    }
                }
                HStack(spacing: 8) {
                    runtimeStatusButton
                    if showsSpotHelp { helpButton }
                    if showsRoute {
                        if let onOpenSaved {
                            savedRoutesButton(onOpenSaved)
                        }
                    } else {
                        favoriteButton
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                if onSelectMode != nil {
                    modeSegmentControl
                        .layoutPriority(3)
                } else {
                    titleText
                }
                if !showsRoute {
                    statusDetailButton
                }
                Spacer(minLength: 4)
                runtimeStatusButton
                    .layoutPriority(1)
                if showsSpotHelp { helpButton }
                if showsRoute {
                    if let onOpenSaved {
                        savedRoutesButton(onOpenSaved)
                    }
                } else {
                    favoriteButton
                }
            }
        }
    }

    private var modeSegmentControl: some View {
        HStack(spacing: 2) {
            modeSegmentItem(title: "定点", icon: "mappin.and.ellipse", isSelected: !showsRoute) {
                onSelectMode?(false)
            }
            modeSegmentItem(title: "路线", icon: "arrow.triangle.swap", isSelected: showsRoute, showBadge: isRouteActive) {
                onSelectMode?(true)
            }
        }
        .padding(2.5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(height: 35)
    }

    private func modeSegmentItem(
        title: String,
        icon: String,
        isSelected: Bool,
        showBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .fixedSize()
                if showBadge {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 70, minHeight: 30)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func savedRoutesButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text("已存")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(HomeInteractiveButtonStyle())
        .accessibilityLabel("打开已存路线管理")
        .accessibilityIdentifier("home.route.openSaved")
    }

    private var titleText: some View {
        HStack(spacing: 5) {
            Image(systemName: showsRoute ? "arrow.triangle.swap" : "mappin.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(displayName)
                .font(.headline)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.tail)
                .id(displayName)
                .transition(.opacity)
        }
        .frame(minWidth: 0, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: displayName)
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
            Image(systemName: showsStatusDetail ? "info.circle.fill" : "info.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomeInteractiveButtonStyle())
        .layoutPriority(1)
        .accessibilityLabel(selectionStatus)
        .accessibilityIdentifier("home.statusDetail")
    }

    @ViewBuilder
    private var statusDetailTip: some View {
        if showsStatusDetail {
            Text(selectionStatus)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 260, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                .padding(.top, 56)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var runtimeStatusButton: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 4) {
                ZStack {
                    if runtimeStatusTone == .ok {
                        Circle()
                            .fill(runtimeStatusTone.color.opacity(0.35))
                            .frame(width: 10, height: 10)
                    }
                    Circle().fill(runtimeStatusTone.color).frame(width: 6, height: 6)
                }
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isFavoriteSelected ? Color.orange : Color.secondary)
                .frame(width: 36, height: 44)
        }
        .buttonStyle(HomeInteractiveButtonStyle())
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
        .buttonStyle(HomeInteractiveButtonStyle())
        .foregroundStyle(.secondary)
        .accessibilityLabel("帮助")
    }

    private var actionRow: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { viaButton; secondaryButton; primaryButton }
            } else {
                HStack(spacing: 8) { viaButton; secondaryButton; primaryButton }
            }
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private var viaButton: some View {
        if let viaTitle {
            Button(viaTitle, action: onViaTap)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control))
                .buttonStyle(HomeInteractiveButtonStyle())
                .disabled(viaDisabled)
                .accessibilityIdentifier("home.via")
        }
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
        .buttonStyle(HomeInteractiveButtonStyle())
        .disabled(primaryDisabled)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: spoofState)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: primaryTitle)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: primaryDisabled)
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
                .frame(maxWidth: (viaTitle != nil || typeSize.isAccessibilitySize) ? .infinity : nil)
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control))
                .buttonStyle(HomeInteractiveButtonStyle())
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
                    .animation(.linear(duration: 0.15), value: playbackClock.progress)
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }
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
