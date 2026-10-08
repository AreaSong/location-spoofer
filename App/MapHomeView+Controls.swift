import SwiftUI
import UIKit

extension MapHomeView {
    @ViewBuilder
    func homeTopArea(availableHeight: CGFloat) -> some View {
        if searchFocused || search.isSearching || !search.results.isEmpty || !search.error.isEmpty {
            VStack(spacing: 6) {
                topControls
                if let block = locationUseBlock {
                    HomeFittingScrollView(maxHeight: 80) { locationUnavailableOverlay(block) }
                        .onAppear { pauseRouteIfLocationBlocked() }
                }
                searchResultList
            }
            .frame(maxHeight: availableHeight, alignment: .top)
            .accessibilityIdentifier("home.topArea")
        } else {
            HomeFittingScrollView(maxHeight: availableHeight) {
                homeTopHeader
            }
            .accessibilityIdentifier("home.topArea")
        }
    }

    private var homeTopHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            topControls
            if let block = locationUseBlock {
                locationUnavailableOverlay(block)
                    .onAppear { pauseRouteIfLocationBlocked() }
            }
            homeCoordinateSummary
            MapZoomControls(
                scaleLabel: MapZoomMath.viewportScaleLabel(distanceMeters: mapState.viewportMeters),
                onZoomIn: { mapState.zoom(by: 0.5) },
                onZoomOut: { mapState.zoom(by: 2) }
            )
        }
    }

    private var homeCoordinateSummary: some View {
        MapHomeCoordinateLine(pair: currentSelectionPair, mapSystem: displayedMapCoordinateSystem)
            .padding(.horizontal, 8)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control))
    }

    var homeMapTools: some View {
        VStack(spacing: AppLayout.mapToolStackSpacing) {
            MapChromeIconButton(systemImage: "square.stack.3d.up", accessibilityLabel: "地图图层") {
                homePopup = nil
                mapStyle.cycle()
            }
            .accessibilityValue(mapStyle.style.title)
            MapChromeIconButton(systemImage: "map.fill", accessibilityLabel: "打开系统地图") {
                homePopup = nil
                if let url = URL(string: "maps://app") { UIApplication.shared.open(url) }
            }
            Button {
                homePopup = nil
                requestRealtimeLocation()
            } label: {
                Group {
                    if realtime.isRequesting {
                        ProgressView()
                    } else {
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: AppLayout.mapToolButtonSize, height: AppLayout.mapToolButtonSize)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
                .contentShape(Circle())
            }
            .buttonStyle(MapChromeIconStyle())
            .accessibilityLabel("回到当前位置")
            .disabled(realtimeButtonTask != nil || realtimeRequestTask != nil || realtime.isRequesting)
        }
        .fixedSize()
        .accessibilityIdentifier("home.mapTools")
    }

    var homeModeAndEntries: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    homeModeButton("定点", selected: !showsRoutePanelActive) {
                        homePopup = nil
                        showsRoutePanel = false
                    }
                    homeModeButton("路线", selected: showsRoutePanelActive) {
                        homePopup = nil
                        enterRoute()
                        showsRoutePanel = true
                    }
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: AppRadius.inset))
                if showsRoutePanelActive {
                    homePopupButton(.points, title: "路线点位")
                    homePopupButton(.savedRoutes, title: "已存路线")
                } else {
                    homePopupButton(.recents, title: "最近", symbol: "clock")
                    homePopupButton(.favorites, title: "收藏", symbol: "star")
                }
            }
        }
        .padding(4)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("home.modeBar")
    }

    private func homeModeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minWidth: 52, minHeight: 44)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .background(selected ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                            in: RoundedRectangle(cornerRadius: AppRadius.inset))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(selected ? "home.mode.selected" : "home.mode.other")
    }

    func toggleHomePopup(_ popup: HomePopup) {
        homePopup = homePopup == popup ? nil : popup
    }

    func homePopupButton(_ popup: HomePopup, title: String, symbol: String? = nil) -> some View {
        Button { toggleHomePopup(popup) } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(2)
                Image(systemName: homePopup == popup ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 4)
            .background(Color.accentColor.opacity(homePopup == popup ? 0.15 : 0.06),
                        in: RoundedRectangle(cornerRadius: AppRadius.inset))
        }
        .buttonStyle(.plain)
        .accessibilityValue(homePopup == popup ? "已展开" : "已收起")
        .accessibilityIdentifier("home.open.\(popup.rawValue)")
    }

    @ViewBuilder
    func homeModeEntryPopup(_ popup: HomePopup) -> some View {
        switch popup {
        case .recents:
            homeRecentList
        case .favorites:
            homeFavoriteList
        case .points:
            routePanel(section: .points)
        case .savedRoutes:
            homeSavedRouteList
        default:
            EmptyView()
        }
    }

    private var homeRecentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recentSelections.items.isEmpty { Text("搜索或点击地图后，选点会出现在这里。").font(.footnote) }
            ForEach(recentSelections.items) { item in
                HStack {
                    Button { selectRecent(item); homePopup = nil } label: {
                        Text(item.name).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    Button { recentSelections.remove(item) } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("从最近选点中删除 \(item.name)")
                }
            }
            if !recentSelections.items.isEmpty {
                Button("清空最近地点") { showsClearHomeRecents = true }
                    .frame(minHeight: 44).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline).buttonStyle(.plain)
        .confirmationDialog("清空最近选点？", isPresented: $showsClearHomeRecents, titleVisibility: .visible) {
            Button("清空", role: .destructive) { recentSelections.removeAll() }
            Button("取消", role: .cancel) {}
        }
    }

    private var homeFavoriteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if favorites.favorites.isEmpty { Text("收藏常用地点，下次可以直接选用。").font(.footnote) }
            ForEach(favorites.displayedFavorites) { favorite in
                Button { select(favorite); homePopup = nil } label: {
                    HStack {
                        Text(favorite.name)
                        Spacer()
                        if favorites.selectedFavoriteID == favorite.id { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            Button("管理收藏") { activeSheet = .favorites }.frame(minHeight: 44)
        }.font(.subheadline)
    }

    private var homeSavedRouteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if savedRoutes.routes.isEmpty { Text("还没有保存的路线。").font(.footnote) }
            ForEach(savedRoutes.routes) { saved in
                Button {
                    let previous = route.phase
                    settleRouteSimulation(after: route.load(saved), from: previous)
                    homePopup = nil
                } label: {
                    HStack {
                        Text(saved.name)
                        Spacer()
                        if route.editingSavedRoute?.id == saved.id { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            Button("管理与导入路线") { openSavedRoutes() }.frame(minHeight: 44)
        }.font(.subheadline)
    }

    var homeSpotControls: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                homePopupButton(
                    .walk,
                    title: "真实走动 · \(physicalWalkStore.isEnabled ? "已开启" : "已关闭")",
                    symbol: "figure.walk"
                )
                if homePopup == .walk {
                    HomePopupSurface(
                        title: "真实走动",
                        onClose: { homePopup = nil },
                        maxHeight: max(88, geometry.size.height)
                    ) {
                        PhysicalWalkHeadingControls(
                            store: physicalWalkStore,
                            controller: physicalWalk,
                            spoofActive: spoofState == .active
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var homeRouteControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            routePanel(section: .summary)
            if let popup = homePopup, popup.isRouteParameter {
                HomePopupSurface(title: popup.title, onClose: { homePopup = nil }) {
                    routePanel(section: RoutePanelSection(popup: popup))
                }
            } else {
                HStack(spacing: 4) {
                    homePopupButton(.travel, title: route.travelMode.displayName)
                    homePopupButton(.speed, title: RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour))
                    homePopupButton(.repetition, title: route.repeatMode.displayName)
                }
                HStack(spacing: 4) {
                    homePopupButton(.offset, title: "偏移 \(Int(route.offsetMeters.rounded())) 米")
                    homePopupButton(.management, title: "路线管理")
                }
            }
        }
    }

    private func routePanel(section: RoutePanelSection) -> some View {
        RoutePlaybackPanel(
            route: route, clock: route.clock, currentPair: currentSelectionPair,
            onExit: requestExitRoute, onSave: promptSaveRoute, onOpenSaved: openSavedRoutes,
            onRestart: { playRoute(fromStart: true) }, embedded: true,
            section: section, onSelection: { homePopup = nil }
        )
    }
}
