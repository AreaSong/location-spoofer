import SwiftUI

/// 底部卡片。定点和走路共用头部、运行状态行和切换条；两种内容由外部组装后传入。
struct MapHomeBottomCard<CoordinateRows: View, SpotContent: View, RoutePanel: View>: View {
    let displayName: String
    let mapSystemName: String
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
    let coordinateRows: CoordinateRows
    let spotContent: SpotContent
    let routePanel: RoutePanel
    let onShowSpot: () -> Void
    let onShowRoute: () -> Void
    let onHelp: () -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void
    let onMainTap: () -> Void
    let onSwitchHere: () -> Void
    @AppStorage("homeCardCompact") private var compact = false

    init(
        displayName: String,
        mapSystemName: String,
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
        @ViewBuilder coordinateRows: () -> CoordinateRows,
        @ViewBuilder spotContent: () -> SpotContent,
        @ViewBuilder routePanel: () -> RoutePanel,
        onShowSpot: @escaping () -> Void,
        onShowRoute: @escaping () -> Void,
        onHelp: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onMainTap: @escaping () -> Void,
        onSwitchHere: @escaping () -> Void
    ) {
        self.displayName = displayName
        self.mapSystemName = mapSystemName
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
        self.coordinateRows = coordinateRows()
        self.spotContent = spotContent()
        self.routePanel = routePanel()
        self.onShowSpot = onShowSpot
        self.onShowRoute = onShowRoute
        self.onHelp = onHelp
        self.onToggleFavorite = onToggleFavorite
        self.onOpenSettings = onOpenSettings
        self.onMainTap = onMainTap
        self.onSwitchHere = onSwitchHere
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            spotHeader
            if !showsRoute && !compact {
                spotContent
            }
            Button(action: onOpenSettings) {
                StatusPill(text: runtimeStatusText, tone: runtimeStatusTone)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(runtimeStatusText)
            .accessibilityHint("打开设置")
            actionSwitcher
            if showsRoute {
                routePanel
            } else {
                spotActions
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showsRoute)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: compact)
    }

    private var spotHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("当前地图：\(mapSystemName)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                coordinateRows
            }
            Spacer(minLength: 4)
            Button(spoofState == .active ? "无法生效？" : "无法取消？", action: onHelp)
                .buttonStyle(CapsuleChipStyle())
            Button(action: onToggleFavorite) {
                Image(systemName: isFavoriteSelected ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background((isFavoriteSelected ? Color.yellow : Color.gray).opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavoriteSelected ? .orange : .gray)
            .disabled(favoriteSaveDisabled)
            .accessibilityLabel(isFavoriteSelected ? "已收藏，点击取消收藏" : "收藏当前选点")
            if !showsRoute {
                Button {
                    compact.toggle()
                } label: {
                    Image(systemName: compact ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(compact ? "展开最近和收藏" : "收起最近和收藏")
            }
        }
    }

    private var actionSwitcher: some View {
        HStack(spacing: 6) {
            switchChip(title: "定点", systemImage: "location.fill", selected: !showsRoute, action: onShowSpot)
            switchChip(title: "走路", systemImage: "figure.walk", subtitle: showsRoute ? nil : routeChipSubtitle, selected: showsRoute, action: onShowRoute)
        }
        .padding(4)
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
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, subtitle == nil ? 8 : 4)
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
            .buttonStyle(PrimaryActionStyle(tint: buttonColor))
            .disabled(spoofState == .verifying)

            if needsSwitchButton {
                Button(action: onSwitchHere) {
                    Label("切换到此处", systemImage: "arrow.triangle.swap")
                        .font(.body.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12).padding(.horizontal, 16)
                }
                .background(.blue, in: RoundedRectangle(cornerRadius: AppRadius.control))
                .foregroundStyle(.white)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: needsSwitchButton)
        .padding(.top, 4)
    }
}

/// 定点卡片里的最近选点和收藏两行。
struct MapHomeSelectionChips<RecentChips: View, FavoriteChips: View, AllFavorites: View>: View {
    let hasRecents: Bool
    let favoritesEmpty: Bool
    let recentChips: RecentChips
    let favoriteChips: FavoriteChips
    let allFavoritesButton: AllFavorites

    init(
        hasRecents: Bool,
        favoritesEmpty: Bool,
        @ViewBuilder recentChips: () -> RecentChips,
        @ViewBuilder favoriteChips: () -> FavoriteChips,
        @ViewBuilder allFavoritesButton: () -> AllFavorites
    ) {
        self.hasRecents = hasRecents
        self.favoritesEmpty = favoritesEmpty
        self.recentChips = recentChips()
        self.favoriteChips = favoriteChips()
        self.allFavoritesButton = allFavoritesButton()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasRecents {
                HStack(spacing: 8) {
                    Text("最近")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            recentChips
                        }
                        .padding(.vertical, 2)
                    }
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
