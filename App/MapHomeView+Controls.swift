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
            homeZoomAndFunctionRow
        }
    }

    private var homeZoomAndFunctionRow: some View {
        MapZoomControls(
            scaleLabel: MapZoomMath.viewportScaleLabel(distanceMeters: mapState.viewportMeters),
            onZoomIn: { mapState.zoom(by: 0.5) },
            onZoomOut: { mapState.zoom(by: 2) }
        )
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: HomeZoomControlFrameKey.self,
                    value: geometry.frame(in: .named("homeOverlay"))
                )
            }
        }
    }

    private var homeCoordinateSummary: some View {
        MapHomeCoordinateLine(
            pair: currentSelectionPair,
            mapSystem: displayedMapCoordinateSystem,
            selectedSystem: previewCoordinateSystem,
            copied: coordinateCopied,
            showsFunction: !showsRoutePanelActive,
            functionSelected: homePopup == .walk,
            functionEnabledDot: physicalWalkStore.isEnabled,
            functionAccessibilityLabel: "功能",
            functionAccessibilityValue: functionAccessibilityValue,
            onCoordinateTap: { toggleHomePopup(.coordinate) },
            onFunctionTap: { toggleHomePopup(.walk) }
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
        let isPhoto = mapStyle.style.isPhotographic
        let barWidth: CGFloat = 42
        let itemHeight: CGFloat = 40
        return VStack(spacing: 0) {
            Button {
                homePopup = nil
                Haptics.light()
                mapStyle.cycle()
            } label: {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: barWidth, height: itemHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MapChromeIconStyle())
            .accessibilityLabel("地图图层")
            .accessibilityValue(mapStyle.style.title)

            Divider()
                .frame(width: 24)
                .opacity(0.4)

            Button {
                homePopup = nil
                if let url = URL(string: "maps://app") { UIApplication.shared.open(url) }
            } label: {
                Image(systemName: "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: barWidth, height: itemHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MapChromeIconStyle())
            .accessibilityLabel("打开系统地图")

            Divider()
                .frame(width: 24)
                .opacity(0.4)

            Button {
                homePopup = nil
                Haptics.light()
                requestRealtimeLocation()
            } label: {
                Group {
                    if realtime.isRequesting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "location.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: barWidth, height: itemHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(MapChromeIconStyle())
            .accessibilityLabel("回到当前位置")
            .disabled(realtimeButtonTask != nil || realtimeRequestTask != nil || realtime.isRequesting)
        }
        .frame(width: barWidth)
        .background(isPhoto ? AnyShapeStyle(.ultraThickMaterial) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                .stroke(isPhoto ? Color.white.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: isPhoto ? 1.0 : 0.5)
        )
        .shadow(color: .black.opacity(isPhoto ? 0.28 : 0.12), radius: isPhoto ? 10 : 8, y: 3)
        .fixedSize()
        .accessibilityIdentifier("home.mapTools")
    }

    var homeModeAndEntries: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                homeModeButton(
                    "定点",
                    icon: "mappin.and.ellipse",
                    selected: !showsRoutePanelActive
                ) {
                    homePopup = nil
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        showsRoutePanel = false
                    }
                }
                homeModeButton(
                    "路线",
                    icon: "arrow.triangle.swap",
                    selected: showsRoutePanelActive,
                    showBadge: route.phase == .playing || route.phase == .paused
                ) {
                    homePopup = nil
                    enterRoute()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        showsRoutePanel = true
                    }
                }
            }
            .padding(3)
            .frame(width: 216, height: 40)
            .background(.thickMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("home.modeBar")
    }

    private func homeModeButton(
        _ title: String,
        icon: String,
        selected: Bool,
        showBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if !selected { Haptics.selection() }
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if showBadge {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                if selected {
                    Capsule()
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 1.5)
                        .matchedGeometryEffect(id: "homeModeSelector", in: modeBarNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(selected ? "home.mode.selected" : "home.mode.other")
    }

    func toggleHomePopup(_ popup: HomePopup) {
        Haptics.selection()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            homePopup = homePopup == popup ? nil : popup
        }
    }

    private var homePopoverTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
        )
    }

    private var functionAccessibilityValue: String {
        var parts: [String] = []
        parts.append("真实走动")
        parts.append(physicalWalkStore.isEnabled ? "已开启" : "已关闭")
        let open = homePopup == .walk
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
                if popup == .coordinate {
                    HStack(alignment: .top, spacing: 0) {
                        Color.clear
                            .frame(width: max(0, coordinateRowFrame.minX))
                            .allowsHitTesting(false)
                        HomeCoordinateMenu(
                            selectedSystem: previewCoordinateSystem,
                            mapSystem: displayedMapCoordinateSystem,
                            onSelect: { system in
                                previewCoordinateSystem = system
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    homePopup = nil
                                }
                            },
                            onCopy: copyPreviewCoordinate
                        )
                        .frame(maxWidth: min(260, coordinateRowFrame.width), alignment: .topLeading)
                        .transition(homePopoverTransition)
                        Spacer(minLength: 0).allowsHitTesting(false)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else if popup == .walk {
                    HStack(alignment: .top, spacing: 0) {
                        Color.clear
                            .frame(width: functionPopoverLeadingX)
                            .allowsHitTesting(false)
                        homeChromePopover(popup)
                            .frame(maxWidth: functionPopoverMaxWidth, alignment: .topLeading)
                            .transition(homePopoverTransition)
                        Spacer(minLength: 0).allowsHitTesting(false)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var functionPopoverLeadingX: CGFloat {
        HomeChromePlacement.functionLeadingX(
            coordinateMinX: coordinateRowFrame.minX,
            zoomFrame: zoomControlFrame
        )
    }

    private var functionPopoverMaxWidth: CGFloat {
        HomeChromePlacement.functionMaxWidth(
            coordinateMaxX: coordinateRowFrame.maxX,
            leadingX: functionPopoverLeadingX,
            cap: AppLayout.homeWalkPopoverMaxWidth
        )
    }

    @ViewBuilder
    private func homeChromePopover(_ popup: HomePopup) -> some View {
        switch popup {
        case .walk:
            HomeToolsPopover(compact: true, hugsHorizontally: false) {
                PhysicalWalkHeadingControls(
                    store: physicalWalkStore,
                    controller: physicalWalk,
                    spoofActive: spoofState == .active
                )
            }
            .accessibilityIdentifier("home.walk.panel")
        default:
            EmptyView()
        }
    }

    func copyPreviewCoordinate() {
        MapHomeCoordinateLine.copy(currentSelectionPair, system: previewCoordinateSystem)
        Haptics.success()
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
        RouteCardControls(
            route: route,
            onSave: promptSaveRoute
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
