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
            homeTopHeader
                .frame(maxWidth: .infinity, maxHeight: availableHeight, alignment: .top)
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
            if showsRoutePanelActive {
                homePanelButton(
                    "参数",
                    popup: .management,
                    accessibilityLabel: "路线参数"
                )
            } else {
                homePanelButton(
                    "走动",
                    popup: .walk,
                    showsEnabledDot: physicalWalkStore.isEnabled,
                    accessibilityLabel: "真实走动"
                )
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
                .frame(maxWidth: .infinity, minHeight: 44)
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

    private func homePanelButton(
        _ title: String,
        popup: HomePopup,
        showsEnabledDot: Bool = false,
        accessibilityLabel: String
    ) -> some View {
        let selected = homePopup == popup
        return Button { toggleHomePopup(popup) } label: {
            HStack(spacing: 6) {
                if showsEnabledDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                        in: RoundedRectangle(cornerRadius: AppRadius.inset))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(panelAccessibilityValue(popup: popup, enabled: showsEnabledDot))
        .accessibilityIdentifier("home.open.\(popup.rawValue)")
    }

    private func panelAccessibilityValue(popup: HomePopup, enabled: Bool) -> String {
        var parts: [String] = []
        if popup == .walk { parts.append(enabled ? "已开启" : "已关闭") }
        parts.append(homePopup == popup ? "已展开" : "已收起")
        return parts.joined(separator: "，")
    }

    var homeSpotControls: some View {
        Group {
            if homePopup == .walk {
                ScrollView {
                    PhysicalWalkHeadingControls(
                        store: physicalWalkStore,
                        controller: physicalWalk,
                        spoofActive: spoofState == .active
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("home.walk.panel")
            } else {
                HomeSpotSwipeLanes(
                    hasRecents: !recentSelections.items.isEmpty,
                    favoritesEmpty: favorites.displayedFavorites.isEmpty,
                    recentBars: {
                        ForEach(recentSelections.items) { item in recentChip(item) }
                    },
                    favoriteBars: {
                        ForEach(favorites.displayedFavorites) { favorite in favoriteChip(favorite) }
                    },
                    onClearRecents: { recentSelections.removeAll() },
                    onManageFavorites: { activeSheet = .favorites }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var homeRouteControls: some View {
        Group {
            if homePopup == .management {
                ScrollView {
                    routePanel(section: .settings)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("home.route.parameters")
            } else {
                HomeRouteSavedList(
                    routes: savedRoutes.routes,
                    selectedID: route.editingSavedRoute?.id,
                    onSelect: { saved in
                        let previous = route.phase
                        settleRouteSimulation(after: route.load(saved), from: previous)
                    },
                    onManage: openSavedRoutes
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func routePanel(section: RoutePanelSection) -> some View {
        RoutePlaybackPanel(
            route: route, clock: route.clock, currentPair: currentSelectionPair,
            onExit: requestExitRoute, onSave: promptSaveRoute, onOpenSaved: openSavedRoutes,
            onRestart: { playRoute(fromStart: true) }, embedded: true,
            section: section, onSelection: {}
        )
    }
}
