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
        MapHomeCoordinateLine(
            pair: currentSelectionPair,
            mapSystem: displayedMapCoordinateSystem,
            selectedSystem: previewCoordinateSystem,
            copied: coordinateCopied,
            showsFunction: true,
            functionSelected: homePopup == .walk || homePopup == .management,
            functionEnabledDot: !showsRoutePanelActive && physicalWalkStore.isEnabled,
            functionAccessibilityLabel: "功能",
            functionAccessibilityValue: functionAccessibilityValue,
            onCoordinateTap: { toggleHomePopup(.coordinate) },
            onFunctionTap: { toggleHomePopup(showsRoutePanelActive ? .management : .walk) }
        )
        .padding(.horizontal, 8)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HomeCoordinateRowFrameKey.self,
                    value: geometry.frame(in: .named("homeOverlay"))
                )
            }
        }
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

    private var functionAccessibilityValue: String {
        var parts: [String] = []
        if showsRoutePanelActive {
            parts.append("路线参数")
        } else {
            parts.append("真实走动")
            parts.append(physicalWalkStore.isEnabled ? "已开启" : "已关闭")
        }
        let open = homePopup == .walk || homePopup == .management
        parts.append(open ? "已展开" : "已收起")
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    var homeChromePopoverOverlay: some View {
        if let popup = homePopup, coordinateRowFrame.width > 1 {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: max(0, coordinateRowFrame.maxY + 6))
                    .allowsHitTesting(false)
                HStack(alignment: .top, spacing: 0) {
                    Color.clear
                        .frame(width: max(0, coordinateRowFrame.minX))
                        .allowsHitTesting(false)
                    homeChromePopover(popup)
                        .frame(width: popoverWidth(for: popup), alignment: .topLeading)
                }
            }
        }
    }

    private func popoverWidth(for popup: HomePopup) -> CGFloat {
        popup == .coordinate ? min(260, coordinateRowFrame.width) : coordinateRowFrame.width
    }

    @ViewBuilder
    private func homeChromePopover(_ popup: HomePopup) -> some View {
        switch popup {
        case .coordinate:
            HomeCoordinateMenu(
                selectedSystem: previewCoordinateSystem,
                mapSystem: displayedMapCoordinateSystem,
                onSelect: { system in
                    previewCoordinateSystem = system
                    homePopup = nil
                },
                onCopy: copyPreviewCoordinate
            )
        case .walk:
            HomeToolsPopover(title: HomePopup.walk.title) {
                PhysicalWalkHeadingControls(
                    store: physicalWalkStore,
                    controller: physicalWalk,
                    spoofActive: spoofState == .active
                )
            }
            .accessibilityIdentifier("home.walk.panel")
        case .management:
            HomeToolsPopover(title: HomePopup.management.title) {
                routePanel(section: .settings)
            }
            .accessibilityIdentifier("home.route.parameters")
        default:
            EmptyView()
        }
    }

    func copyPreviewCoordinate() {
        MapHomeCoordinateLine.copy(currentSelectionPair, system: previewCoordinateSystem)
        coordinateCopyGeneration += 1
        let current = coordinateCopyGeneration
        withAnimation(.easeInOut(duration: 0.15)) { coordinateCopied = true }
        homePopup = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard coordinateCopyGeneration == current else { return }
            withAnimation(.easeInOut(duration: 0.15)) { coordinateCopied = false }
        }
    }

    var homeSpotControls: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var homeRouteControls: some View {
        HomeRouteSavedList(
            routes: savedRoutes.routes,
            selectedID: route.editingSavedRoute?.id,
            onSelect: { saved in
                let previous = route.phase
                settleRouteSimulation(after: route.load(saved), from: previous)
            },
            onManage: openSavedRoutes
        )
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
