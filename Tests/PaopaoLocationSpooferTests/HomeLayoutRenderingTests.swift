import SwiftUI
import XCTest
@testable import PaopaoLocationSpoofer

/// 使用真实首页组件的隔离渲染；地图、传感器与定位写入不参与此测试。
@MainActor
final class HomeLayoutRenderingTests: XCTestCase {
    func testHomeLayouts() {
        let scenarios: [(String, CGSize, Bool, DynamicTypeSize, Bool, Bool)] = [
            ("spot-light", CGSize(width: 375, height: 667), false, .large, false, false),
            ("spot-dark-expanded", CGSize(width: 375, height: 667), true, .large, true, false),
            ("route-expanded", CGSize(width: 393, height: 852), false, .large, true, true),
            ("spot-accessibility5", CGSize(width: 375, height: 667), false, .accessibility5, true, false),
            ("route-landscape", CGSize(width: 667, height: 375), true, .large, true, true)
        ]
        for (name, size, dark, typeSize, expanded, route) in scenarios {
            let content = HomeLayoutFixture(size: size, expanded: expanded, showsRoute: route)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dynamicTypeSize, typeSize)
            let host = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(rendered.size, size)
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "home-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }
}

@MainActor
private struct HomeLayoutFixture: View {
    let size: CGSize
    let expanded: Bool
    let showsRoute: Bool
    @StateObject private var search = MapSearchModel()
    @StateObject private var route = RoutePlaybackController()
    @FocusState private var focused: Bool
    private let now = Date(timeIntervalSince1970: 1_791_100_000)
    private let pair = CoordinateConverter.coordinatePair(lat: 22.5, lon: 113.9, mapCoordinateSystem: .wgs84)

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                MapSearchField(search: search, focus: $focused, onSubmit: {})
                MapChromeIconButton(systemImage: "list.bullet.rectangle", accessibilityLabel: "日志", action: {})
                HomeSettingsButton(status: SigningExpiry.evaluate(expirationDate: now.addingTimeInterval(90_000), now: now),
                                   now: now, onOpen: {})
            }
            Spacer(minLength: 0)
            card
        }
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemGroupedBackground))
        .ignoresSafeArea()
    }

    private var card: some View {
        MapHomeBottomCard(
            displayName: showsRoute ? "深圳湾公园步行路线" : "深圳湾公园·海风运动广场",
            selectionStatus: showsRoute ? "路线已暂停" : "新选位置 · 尚未切换",
            spoofState: .active, isFavoriteSelected: true, favoriteSaveDisabled: false,
            runtimeStatusText: "模块已连接", runtimeStatusTone: .ok, showsRoute: showsRoute,
            routeChipSubtitle: nil, showsRouteProgress: showsRoute,
            primaryTitle: showsRoute ? "继续" : "切换到此处",
            primaryAccessibilityLabel: showsRoute ? "继续路线" : "切换到此处",
            primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
            secondaryTitle: showsRoute ? "结束路线" : "停止定位", secondaryDisabled: false, showsSpotHelp: false,
            expandedMaxHeight: size.height * 0.28, availableHeight: size.height - 100,
            isExpanded: .constant(expanded), playbackClock: route.clock,
            spotContent: {
                VStack(alignment: .leading, spacing: 12) {
                    MapHomeSelectionChips(hasRecents: true, favoritesEmpty: false,
                                          recentChips: { Text("深圳湾公园").frame(minHeight: 44) },
                                          favoriteChips: { Text("海风运动广场").frame(minHeight: 44) },
                                          allFavoritesButton: { Button("全部", action: {}) })
                    MapHomeCoordinateLine(pair: pair, mapSystem: .wgs84)
                }
            },
            routePanel: {
                RoutePlaybackPanel(route: route, clock: route.clock, currentPair: pair,
                                   onExit: {}, onSave: {}, onOpenSaved: {}, onRestart: {}, embedded: true)
            },
            caption: { EmptyView() }, onShowSpot: {}, onShowRoute: {}, onHelp: {}, onToggleFavorite: {},
            onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {}
        )
    }
}
