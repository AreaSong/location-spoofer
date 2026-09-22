import SwiftUI

struct MapHomeBottomCard<CoordinateRows: View, RecentChips: View, FavoriteChips: View, AllFavorites: View>: View {
    let displayName: String
    let mapSystemName: String
    let spoofState: SpoofState
    let isFavoriteSelected: Bool
    let favoriteSaveDisabled: Bool
    let hasRecents: Bool
    let favoritesEmpty: Bool
    let runtimeStatusText: String
    let needsSwitchButton: Bool
    let buttonTitle: String
    let buttonColor: Color
    let coordinateRows: CoordinateRows
    let recentChips: RecentChips
    let favoriteChips: FavoriteChips
    let allFavoritesButton: AllFavorites
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
        hasRecents: Bool,
        favoritesEmpty: Bool,
        runtimeStatusText: String,
        needsSwitchButton: Bool,
        buttonTitle: String,
        buttonColor: Color,
        @ViewBuilder coordinateRows: () -> CoordinateRows,
        @ViewBuilder recentChips: () -> RecentChips,
        @ViewBuilder favoriteChips: () -> FavoriteChips,
        @ViewBuilder allFavoritesButton: () -> AllFavorites,
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
        self.hasRecents = hasRecents
        self.favoritesEmpty = favoritesEmpty
        self.runtimeStatusText = runtimeStatusText
        self.needsSwitchButton = needsSwitchButton
        self.buttonTitle = buttonTitle
        self.buttonColor = buttonColor
        self.coordinateRows = coordinateRows()
        self.recentChips = recentChips()
        self.favoriteChips = favoriteChips()
        self.allFavoritesButton = allFavoritesButton()
        self.onHelp = onHelp
        self.onToggleFavorite = onToggleFavorite
        self.onOpenSettings = onOpenSettings
        self.onMainTap = onMainTap
        self.onSwitchHere = onSwitchHere
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            Button(action: onOpenSettings) {
                Text(runtimeStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(runtimeStatusText)
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
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}
