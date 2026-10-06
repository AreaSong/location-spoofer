import SwiftUI
import XCTest
@testable import PaopaoLocationSpoofer

/// 使用真实首页组件的隔离渲染；地图、传感器与定位写入不参与此测试。
@MainActor
final class HomeLayoutRenderingTests: XCTestCase {
    func testRegionsProtectCenterAndRespectSafeArea() {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852), CGSize(width: 667, height: 375)] {
            let safe = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
            let regions = MapHomeOverlayRegions(size: size, safeArea: safe)
            for panel in [regions.top, regions.bottom] {
                XCTAssertFalse(panel.intersects(regions.protectedCenter))
                XCTAssertGreaterThanOrEqual(panel.minY, 59)
                XCTAssertLessThanOrEqual(panel.maxY, size.height - 34)
                XCTAssertGreaterThan(panel.width, 0)
                XCTAssertGreaterThan(panel.height, 0)
            }
            XCTAssertEqual(regions.protectedCenter.midX, size.width / 2)
            XCTAssertEqual(regions.protectedCenter.midY, size.height / 2)
            XCTAssertGreaterThanOrEqual(regions.protectedCenter.width, 120)
            XCTAssertGreaterThanOrEqual(regions.protectedCenter.height, 120)
        }
    }

    func testHomeLayouts() {
        let scenarios: [(String, CGSize, Bool, DynamicTypeSize, Bool, Bool)] = [
            ("spot-light", CGSize(width: 375, height: 667), false, .large, false, false),
            ("spot-dark-expanded", CGSize(width: 375, height: 667), true, .large, true, false),
            ("route-expanded", CGSize(width: 393, height: 852), false, .large, true, true),
            ("spot-accessibility5", CGSize(width: 375, height: 667), false, .accessibility5, true, false),
            ("route-landscape", CGSize(width: 667, height: 375), true, .large, true, true)
        ]
        for (name, size, dark, typeSize, expanded, route) in scenarios {
            let bounds = HomeLayoutBounds()
            let content = HomeLayoutFixture(size: size, expanded: expanded, showsRoute: route, bounds: bounds)
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
            let center = CGRect(x: size.width / 2 - 60, y: size.height / 2 - 60, width: 120, height: 120)
            for key in ["top", "bottom"] {
                guard let frame = bounds.frames[key] else { XCTFail("Missing rendered \(key) bounds"); continue }
                XCTAssertFalse(frame.intersects(center), "\(name): \(key) covers the selection center: \(frame)")
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, size.height + 1)
            }
            if name == "spot-light", let frame = bounds.frames["bottom"] {
                XCTAssertLessThan(frame.height, 250, "Short content must not fill all available map space")
            }
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
    let bounds: HomeLayoutBounds
    @StateObject private var search = MapSearchModel()
    @StateObject private var route = RoutePlaybackController()
    @FocusState private var focused: Bool
    private let now = Date(timeIntervalSince1970: 1_791_100_000)
    private let pair = CoordinateConverter.coordinatePair(lat: 22.5, lon: 113.9, mapCoordinateSystem: .wgs84)

    var body: some View {
        MapHomeOverlayLayout(top: { height in
            HomeFittingScrollView(maxHeight: height) {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        MapSearchField(search: search, focus: $focused, onSubmit: {})
                        MapChromeIconButton(systemImage: "list.bullet.rectangle", accessibilityLabel: "日志", action: {})
                    }
                    Text("22.500000, 113.900000").font(.caption.monospaced()).frame(minHeight: 44)
                    HStack {
                        Button("定点", action: {})
                        Button("路线", action: {})
                        Button(showsRoute ? "路线点位" : "最近", action: {})
                        Button(showsRoute ? "已存路线" : "收藏", action: {})
                    }.frame(minHeight: 44)
                    if expanded {
                        HomePopupSurface(title: showsRoute ? "路线点位" : "收藏地点", onClose: {}) {
                            ForEach(0..<20) { index in
                                Button("\(index + 1) · 深圳湾公园海风运动广场入口", action: {}).frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .background(measure("top"))
        }, bottom: { height in
            card(availableHeight: height).background(measure("bottom"))
        })
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemGroupedBackground))
        .ignoresSafeArea()
    }

    private func measure(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.onAppear { bounds.frames[key] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { bounds.frames[key] = $0 }
        }
    }

    private func card(availableHeight: CGFloat) -> some View {
        MapHomeBottomCard(
            displayName: showsRoute ? "深圳湾公园步行路线" : "深圳湾公园·海风运动广场",
            selectionStatus: showsRoute ? "路线已暂停" : "新选位置 · 尚未切换",
            spoofState: .active, isFavoriteSelected: true, favoriteSaveDisabled: false,
            runtimeStatusText: "模块已连接", runtimeStatusTone: .ok, showsRoute: showsRoute,
            showsRouteProgress: showsRoute,
            primaryTitle: showsRoute ? "继续" : "切换到此处",
            primaryAccessibilityLabel: showsRoute ? "继续路线" : "切换到此处",
            primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
            secondaryTitle: showsRoute ? "结束路线" : "停止定位", secondaryDisabled: false, showsSpotHelp: false,
            availableHeight: availableHeight,
            playbackClock: route.clock,
            spotContent: { Button("真实走动 · 已关闭", action: {}).frame(minHeight: 44) },
            routePanel: {
                RoutePlaybackPanel(route: route, clock: route.clock, currentPair: pair,
                                   onExit: {}, onSave: {}, onOpenSaved: {}, onRestart: {}, embedded: true)
            },
            caption: { EmptyView() }, onHelp: {}, onToggleFavorite: {},
            onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {}
        )
    }
}

@MainActor
private final class HomeLayoutBounds {
    var frames: [String: CGRect] = [:]
}
