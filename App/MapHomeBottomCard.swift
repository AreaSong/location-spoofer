import SwiftUI

/// 底部卡片。收起时只留地名、模式切换和主按钮；最近与收藏点开后出现。
struct MapHomeBottomCard<QuickActions: View, SpotContent: View, RoutePanel: View, PeekCaption: View>: View {
    let displayName: String
    let spoofState: SpoofState
    let isFavoriteSelected: Bool
    let favoriteSaveDisabled: Bool
    let runtimeStatusText: String
    let runtimeStatusTone: StatusPill.Tone
    let needsSwitchButton: Bool
    let buttonTitle: String
    let buttonSystemImage: String?
    let buttonColor: Color
    let showsRoute: Bool
    let routeChipSubtitle: String?
    let spotChipSubtitle: String?
    let showsRouteProgress: Bool
    let peekTitle: String
    let peekAccessibilityLabel: String
    let peekSystemImage: String?
    let peekColor: Color
    let peekDisabled: Bool
    let peekOpensDetail: Bool
    let showsSpotHelp: Bool
    let expandedMaxHeight: CGFloat
    let quickActions: QuickActions
    let spotContent: SpotContent
    let routePanel: RoutePanel
    let peekCaption: PeekCaption
    let onShowSpot: () -> Void
    let onShowRoute: () -> Void
    let onHelp: () -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void
    let onMainTap: () -> Void
    let onSwitchHere: () -> Void
    let onPeekTap: () -> Void
    @ObservedObject var playbackClock: RoutePlaybackClock
    @State private var isExpanded = false
    @State private var expandedContentHeight: CGFloat = 0

    init(
        displayName: String,
        spoofState: SpoofState,
        isFavoriteSelected: Bool,
        favoriteSaveDisabled: Bool,
        runtimeStatusText: String,
        runtimeStatusTone: StatusPill.Tone,
        needsSwitchButton: Bool,
        buttonTitle: String,
        buttonSystemImage: String? = nil,
        buttonColor: Color,
        showsRoute: Bool,
        routeChipSubtitle: String? = nil,
        spotChipSubtitle: String? = nil,
        showsRouteProgress: Bool,
        peekTitle: String,
        peekAccessibilityLabel: String,
        peekSystemImage: String? = nil,
        peekColor: Color,
        peekDisabled: Bool,
        peekOpensDetail: Bool,
        showsSpotHelp: Bool = true,
        expandedMaxHeight: CGFloat,
        playbackClock: RoutePlaybackClock,
        @ViewBuilder quickActions: () -> QuickActions,
        @ViewBuilder spotContent: () -> SpotContent,
        @ViewBuilder routePanel: () -> RoutePanel,
        @ViewBuilder peekCaption: () -> PeekCaption,
        onShowSpot: @escaping () -> Void,
        onShowRoute: @escaping () -> Void,
        onHelp: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onMainTap: @escaping () -> Void,
        onSwitchHere: @escaping () -> Void,
        onPeekTap: @escaping () -> Void
    ) {
        self.displayName = displayName
        self.spoofState = spoofState
        self.isFavoriteSelected = isFavoriteSelected
        self.favoriteSaveDisabled = favoriteSaveDisabled
        self.runtimeStatusText = runtimeStatusText
        self.runtimeStatusTone = runtimeStatusTone
        self.needsSwitchButton = needsSwitchButton
        self.buttonTitle = buttonTitle
        self.buttonSystemImage = buttonSystemImage
        self.buttonColor = buttonColor
        self.showsRoute = showsRoute
        self.routeChipSubtitle = routeChipSubtitle
        self.spotChipSubtitle = spotChipSubtitle
        self.showsRouteProgress = showsRouteProgress
        self.peekTitle = peekTitle
        self.peekAccessibilityLabel = peekAccessibilityLabel
        self.peekSystemImage = peekSystemImage
        self.peekColor = peekColor
        self.peekDisabled = peekDisabled
        self.peekOpensDetail = peekOpensDetail
        self.showsSpotHelp = showsSpotHelp
        self.expandedMaxHeight = expandedMaxHeight
        self.quickActions = quickActions()
        self.spotContent = spotContent()
        self.routePanel = routePanel()
        self.peekCaption = peekCaption()
        self.onShowSpot = onShowSpot
        self.onShowRoute = onShowRoute
        self.onHelp = onHelp
        self.onToggleFavorite = onToggleFavorite
        self.onOpenSettings = onOpenSettings
        self.onMainTap = onMainTap
        self.onSwitchHere = onSwitchHere
        self.onPeekTap = onPeekTap
        _playbackClock = ObservedObject(wrappedValue: playbackClock)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            peekHeader
            peekActionRow
            if !showsRoute {
                quickActions
            }
            if isExpanded {
                expandedDetail
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background { cardBackground }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showsRoute)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isExpanded)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
            .fill(.regularMaterial)
            .overlay(alignment: .top) { routeProgressBar }
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    @ViewBuilder
    private var routeProgressBar: some View {
        if showsRouteProgress {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * playbackClock.progress))
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    private var peekHeader: some View {
        HStack(spacing: 4) {
            Button(action: toggleExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !isExpanded {
                        peekCaption
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityHint(isExpanded ? "收起详情" : "展开详情")
            if isExpanded && showsSpotHelp {
                helpButton
            }
            statusDot
            favoriteButton
            expandButton
        }
    }

    private var helpButton: some View {
        Button(action: onHelp) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoofState == .active ? "无法生效？" : "无法取消？")
        .accessibilityHint("打开说明")
    }

    private var statusDot: some View {
        Button(action: onOpenSettings) {
            Circle()
                .fill(runtimeStatusTone.color)
                .frame(width: 8, height: 8)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(runtimeStatusText)
        .accessibilityHint("打开设置")
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavoriteSelected ? "star.fill" : "star")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background((isFavoriteSelected ? Color.yellow : Color.gray).opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isFavoriteSelected ? .orange : .gray)
        .disabled(favoriteSaveDisabled)
        .accessibilityLabel(isFavoriteSelected ? "已收藏，点击取消收藏" : "收藏当前选点")
    }

    private var expandButton: some View {
        Button(action: toggleExpanded) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起详情" : "展开详情")
    }

    private var peekActionRow: some View {
        HStack(spacing: 8) {
            actionSwitcher
            peekButton
        }
    }

    private var peekButton: some View {
        Button(action: handlePeekTap) {
            HStack(spacing: 4) {
                if spoofState == .verifying, !showsRoute {
                    ProgressView().tint(.white).controlSize(.small)
                } else if let peekSystemImage {
                    Image(systemName: peekSystemImage)
                }
                Text(peekTitle).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
                .frame(minWidth: 96)
                .padding(.horizontal, 10)
                .frame(height: 44)
            .background(
                peekColor.opacity(peekDisabled ? 0.45 : 1),
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(peekDisabled)
        .accessibilityLabel(peekAccessibilityLabel)
        .accessibilityHint(peekOpensDetail ? "展开路线设置" : "")
    }

    private var actionSwitcher: some View {
        HStack(spacing: 6) {
            switchChip(
                title: "定点",
                systemImage: "location.fill",
                subtitle: spotChipSubtitle,
                selected: !showsRoute,
                action: onShowSpot
            )
            switchChip(title: "走路",
                systemImage: "figure.walk",
                subtitle: showsRoute ? nil : routeChipSubtitle,
                selected: showsRoute,
                action: onShowRoute
            )
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    private func switchChip(
        title: String,
        systemImage: String,
        subtitle: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                selected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(subtitle.map { "\(title)，\($0)" } ?? title)
    }

    @ViewBuilder
    private var expandedDetail: some View {
        if showsRoute {
            routePanel
        } else {
            ScrollView {
                expandedSpot
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ExpandedHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .onPreferenceChange(ExpandedHeightKey.self) { height in
                guard abs(expandedContentHeight - height) > 0.5 else { return }
                expandedContentHeight = height
            }
            .frame(maxHeight: min(expandedContentHeight > 0 ? expandedContentHeight : expandedMaxHeight, expandedMaxHeight))
        }
    }

    private var expandedSpot: some View {
        VStack(alignment: .leading, spacing: 8) {
            spotContent
            if needsSwitchButton {
                spotActions
            }
        }
    }

    private var spotActions: some View {
        HStack(spacing: 10) {
            Button(action: onMainTap) {
                HStack(spacing: 6) {
                    if spoofState == .verifying {
                        ProgressView().tint(.white)
                    } else if let buttonSystemImage {
                        Image(systemName: buttonSystemImage)
                    }
                    Text(spoofState == .active && needsSwitchButton ? "关闭" : buttonTitle)
                }
                .frame(maxWidth: needsSwitchButton ? nil : .infinity)
                .frame(minWidth: needsSwitchButton ? 56 : nil)
                .padding(.horizontal, needsSwitchButton ? 12 : 14)
            }
            .buttonStyle(PrimaryActionStyle(tint: buttonColor, compact: true))
            .disabled(spoofState == .verifying)

            if needsSwitchButton {
                Button(action: onSwitchHere) {
                    Label("切换到此处", systemImage: "arrow.triangle.swap")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                }
                .background(.blue, in: RoundedRectangle(cornerRadius: AppRadius.control))
                .foregroundStyle(.white)
            }
        }
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }

    private func handlePeekTap() {
        if peekOpensDetail {
            isExpanded = true
            return
        }
        onPeekTap()
    }
}

private enum ExpandedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

