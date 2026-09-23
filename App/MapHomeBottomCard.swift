import SwiftUI

/// 底部卡片。定点和走路共用头部、运行状态行和切换条；两种内容由外部组装后传入。
struct MapHomeBottomCard<CoordinateRows: View, SpotContent: View, RoutePanel: View>: View {
    let displayName: String
    let mapSystemName: String
    let spoofState: SpoofState
    let isFavoriteSelected: Bool
    let favoriteSaveDisabled: Bool
    let runtimeStatusText: String
    let needsSwitchButton: Bool
    let buttonTitle: String
    let buttonColor: Color
    let showsRoute: Bool
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

    init(
        displayName: String,
        mapSystemName: String,
        spoofState: SpoofState,
        isFavoriteSelected: Bool,
        favoriteSaveDisabled: Bool,
        runtimeStatusText: String,
        needsSwitchButton: Bool,
        buttonTitle: String,
        buttonColor: Color,
        showsRoute: Bool,
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
        self.needsSwitchButton = needsSwitchButton
        self.buttonTitle = buttonTitle
        self.buttonColor = buttonColor
        self.showsRoute = showsRoute
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
            if !showsRoute {
                spotContent
            }
            Button(action: onOpenSettings) {
                Text(runtimeStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(runtimeStatusText)
            actionSwitcher
            if showsRoute {
                routePanel
            } else {
                spotActions
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showsRoute)
    }

    private var spotHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("当前地图：\(mapSystemName)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                coordinateRows
            }
            Spacer()
            Button(action: onHelp) {
                Text(spoofState == .active ? "无法生效？" : "无法取消？")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
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
        }
    }

    private var actionSwitcher: some View {
        HStack(spacing: 6) {
            switchChip(title: "定点", systemImage: "location.fill", selected: !showsRoute, action: onShowSpot)
            switchChip(title: "走路", systemImage: "figure.walk", selected: showsRoute, action: onShowRoute)
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func switchChip(title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var spotActions: some View {
        HStack(spacing: 10) {
            Button(action: onMainTap) {
                HStack(spacing: 6) {
                    if spoofState == .verifying {
                        ProgressView().tint(.white)
                    }
                    Text(spoofState == .active && needsSwitchButton ? "关闭" : buttonTitle)
                        .font(.headline).lineLimit(1)
                }
                .frame(maxWidth: needsSwitchButton ? nil : .infinity)
                .frame(minWidth: needsSwitchButton ? 56 : nil)
                .padding(.vertical, 14)
                .padding(.horizontal, needsSwitchButton ? 12 : 14)
            }
            .background(buttonColor, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .disabled(spoofState == .verifying)

            if needsSwitchButton {
                Button(action: onSwitchHere) {
                    Label("切换到此处", systemImage: "arrow.triangle.swap")
                        .font(.body.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12).padding(.horizontal, 16)
                }
                .background(.blue, in: RoundedRectangle(cornerRadius: 14))
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
