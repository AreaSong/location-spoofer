import SwiftUI
import XCTest
@testable import PaopaoLocationSpoofer

/// 使用真实首页组件的隔离渲染；地图、传感器与定位写入不参与此测试。
@MainActor
final class HomeLayoutRenderingTests: XCTestCase {
    func testRegionsProtectCenterAndRespectSafeArea() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667), CGSize(width: 393, height: 852), CGSize(width: 667, height: 375)] {
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

    func testFunctionPopoverSitsToTheRightOfZoomControls() {
        let suite = "WalkBesideZoom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhysicalWalkStore(defaults: defaults)
        store.setEnabled(true)
        store.setCustomHeadingEnabled(true)
        let bounds = HomeLayoutBounds()
        let row = HStack(alignment: .top, spacing: 12) {
            MapZoomControls(scaleLabel: "50米", onZoomIn: {}, onZoomOut: {})
                .background(bounds.measure("zoom"))
            HomeToolsPopover(compact: true, hugsHorizontally: false) {
                PhysicalWalkHeadingControls(
                    store: store, controller: PhysicalWalkController(), spoofActive: true
                )
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .clipped()
            .background(bounds.measure("walk"))
        }
        .frame(width: 369, alignment: .leading)
        let host = UIHostingController(rootView: row.frame(maxHeight: 400, alignment: .topLeading))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let zoom = bounds.frames["zoom"] ?? .zero
        let walk = bounds.frames["walk"] ?? .zero
        XCTAssertGreaterThan(zoom.width, 1, "zoom controls must render, got \(zoom)")
        XCTAssertGreaterThan(walk.width, 1, "walk panel must render, got \(walk)")
        XCTAssertGreaterThanOrEqual(walk.minX, zoom.maxX + 11, "function panel must leave a gap after zoom, zoom=\(zoom) walk=\(walk)")
        XCTAssertGreaterThanOrEqual(zoom.width, AppLayout.mapZoomControlSize - 1, "zoom card must stay fully visible, got \(zoom)")
        XCTAssertLessThan(zoom.height, 150, "zoom controls must keep their compact stack, got \(zoom)")
        XCTAssertGreaterThanOrEqual(
            descendants(of: host.view).compactMap { $0 as? UISlider }.count, 2,
            "walk panel must keep heading and stride sliders"
        )
        window.isHidden = true
    }

    func testBoundedPopupKeepsLargeHeaderInsideItsHeight() {
        for typeSize in [DynamicTypeSize.large, .accessibility5] {
            let bounds = HomeLayoutBounds()
            let popup = HomePopupSurface(title: "收藏地点", onClose: {}, maxHeight: 180) {
                ForEach(0..<20) { index in Text("地点 \(index)").frame(minHeight: 44) }
            }
            .environment(\.dynamicTypeSize, typeSize)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { bounds.frames["popup"] = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { bounds.frames["popup"] = $0 }
                }
            }
            let host = UIHostingController(rootView: VStack { popup; Spacer() })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertLessThanOrEqual(bounds.frames["popup"]?.height ?? .infinity, 180)
            let scrollViews = descendants(of: host.view).compactMap { $0 as? UIScrollView }
            let scroll = scrollViews.first { $0.contentSize.height > $0.bounds.height + 44 }
            XCTAssertNotNil(scroll, "Long popup must expose a scrollable range")
            if let scroll {
                XCTAssertGreaterThanOrEqual(scroll.bounds.height, 44, "At least one option must remain reachable")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                XCTAssertGreaterThan(scroll.contentOffset.y, 44)
            }
            window.isHidden = true
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func visibleTexts(in view: UIView) -> [String] {
        accessibilityStrings(from: view)
    }

    private func accessibilityStrings(from object: NSObject) -> [String] {
        var values: [String] = []
        collectAccessibilityStrings(from: object, into: &values)
        return values
    }

    private func collectAccessibilityStrings(from object: NSObject, into values: inout [String]) {
        for candidate in [
            object.accessibilityLabel,
            object.accessibilityValue as? String,
            (object as? UILabel)?.text,
            (object as? UILabel)?.attributedText?.string,
            (object as? UIButton)?.currentTitle,
            (object as? UITextView)?.text
        ] {
            if let candidate, !candidate.isEmpty, !values.contains(candidate) {
                values.append(candidate)
            }
        }
        if let view = object as? UIView {
            if let elements = view.accessibilityElements {
                for element in elements {
                    if let object = element as? NSObject {
                        collectAccessibilityStrings(from: object, into: &values)
                    }
                }
            }
            for subview in view.subviews {
                collectAccessibilityStrings(from: subview, into: &values)
            }
        }
    }

    func testSpotAndRouteCardsShareFixedHeight() {
        let budget = AppLayout.homeFunctionCardHeight
        XCTAssertEqual(cardHeight(showsRoute: false, availableHeight: budget), budget, accuracy: 2)
        XCTAssertEqual(cardHeight(showsRoute: true, availableHeight: budget), budget, accuracy: 2)
    }

    func testModeSegmentControlIntegration() {
        var selectedMode: Bool? = nil
        let route = RoutePlaybackController()
        let card = MapHomeBottomCard(
            displayName: "当前选点",
            selectionStatus: "未开启",
            spoofState: .idle, isFavoriteSelected: false, favoriteSaveDisabled: false,
            runtimeStatusText: "开发者模式", runtimeStatusTone: .ok, showsRoute: false,
            showsRouteProgress: false,
            primaryTitle: "连接隧道",
            primaryAccessibilityLabel: "连接隧道",
            primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
            secondaryTitle: nil as String?, secondaryDisabled: false, showsSpotHelp: false,
            availableHeight: 244,
            playbackClock: route.clock,
            spotContent: { Color.clear },
            routePanel: { Color.clear },
            caption: { EmptyView() }, onHelp: {}, onToggleFavorite: {},
            onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {},
            isRouteActive: false,
            onSelectMode: { isRoute in
                selectedMode = isRoute
            }
        )
        let host = UIHostingController(rootView: card)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 244))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        
        let texts = visibleTexts(in: host.view)
        XCTAssertTrue(texts.contains("定点"), "卡片顶栏必须展示定点分段")
        XCTAssertTrue(texts.contains("路线"), "卡片顶栏必须展示路线分段")
    }

    private func cardHeight(showsRoute: Bool, availableHeight: CGFloat) -> CGFloat {
        let bounds = HomeLayoutBounds()
        let route = RoutePlaybackController()
        let card = MapHomeBottomCard(
            displayName: showsRoute ? "当前路线" : "当前选点",
            selectionStatus: showsRoute ? "请设置起点和终点" : "已选位置 · 尚未开始",
            spoofState: .idle, isFavoriteSelected: false, favoriteSaveDisabled: false,
            runtimeStatusText: "开发者模式", runtimeStatusTone: .ok, showsRoute: showsRoute,
            showsRouteProgress: false,
            primaryTitle: showsRoute ? "设为起点" : "连接隧道",
            primaryAccessibilityLabel: showsRoute ? "设为起点" : "连接隧道",
            primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
            secondaryTitle: nil as String?, secondaryDisabled: false, showsSpotHelp: false,
            availableHeight: availableHeight,
            playbackClock: route.clock,
            spotContent: { Button("走动", action: {}).frame(minHeight: 44) },
            routePanel: {
                HomeRouteSavedList(routes: [], selectedID: nil, onSelect: { _ in }, onManage: {})
            },
            caption: { EmptyView() }, onHelp: {}, onToggleFavorite: {},
            onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {}
        )
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { bounds.frames["card"] = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { bounds.frames["card"] = $0 }
            }
        }
        let host = UIHostingController(rootView: card)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let height = bounds.frames["card"]?.height ?? -1
        window.isHidden = true
        return height
    }

    func testRuntimeStatusSitsOnTheTitleRow() {
        for showsRoute in [false, true] {
            let bounds = HomeLayoutBounds()
            let route = RoutePlaybackController()
            let card = MapHomeBottomCard(
                displayName: showsRoute ? "当前路线" : "当前选点",
                selectionStatus: showsRoute ? "请设置起点和终点" : "已选位置 · 尚未开始",
                spoofState: .idle, isFavoriteSelected: false, favoriteSaveDisabled: false,
                runtimeStatusText: "开发者模式", runtimeStatusTone: .ok, showsRoute: showsRoute,
                showsRouteProgress: false,
                primaryTitle: showsRoute ? "设为起点" : "连接隧道",
                primaryAccessibilityLabel: showsRoute ? "设为起点" : "连接隧道",
                primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
                secondaryTitle: nil as String?, secondaryDisabled: false, showsSpotHelp: false,
                availableHeight: 240,
                playbackClock: route.clock,
                spotContent: { Color.clear.frame(height: 44) },
                routePanel: { Color.clear.frame(height: 88) },
                caption: { EmptyView() }, onHelp: {}, onToggleFavorite: {},
                onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {}
            )
            .onPreferenceChange(HomeCardTitleFrameKey.self) { bounds.frames["title"] = $0 }
            .onPreferenceChange(HomeRuntimeStatusFrameKey.self) { bounds.frames["status"] = $0 }
            let host = UIHostingController(rootView: card)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let mode = showsRoute ? "route" : "spot"
            guard let title = bounds.frames["title"], let status = bounds.frames["status"] else {
                XCTFail("Missing title/status frames in \(mode)")
                window.isHidden = true
                continue
            }
            XCTAssertEqual(title.midY, status.midY, accuracy: 18, "\(mode) status must share the title row")
            XCTAssertGreaterThan(status.minX, title.minX + 40, "\(mode) status must sit to the right of the title")
            window.isHidden = true
        }
    }

    func testSelectionCaptionDoesNotAddAHeaderRow() {
        let bounds = HomeLayoutBounds()
        let route = RoutePlaybackController()
        let card = MapHomeBottomCard(
            displayName: "当前选点",
            selectionStatus: "已选位置 · 尚未开始",
            spoofState: .idle, isFavoriteSelected: false, favoriteSaveDisabled: false,
            runtimeStatusText: "开发者模式", runtimeStatusTone: .ok, showsRoute: false,
            showsRouteProgress: false,
            primaryTitle: "连接隧道", primaryAccessibilityLabel: "连接隧道",
            primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
            secondaryTitle: nil as String?, secondaryDisabled: false, showsSpotHelp: false,
            availableHeight: 240,
            playbackClock: route.clock,
            spotContent: { Color.clear.frame(height: 44) },
            routePanel: { EmptyView() },
            caption: { Text("已设路线").font(.caption) },
            onHelp: {}, onToggleFavorite: {}, onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {}
        )
        .onPreferenceChange(HomeCardHeaderHeightKey.self) {
            bounds.frames["header"] = CGRect(x: 0, y: 0, width: 0, height: $0)
        }
        let host = UIHostingController(rootView: card)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let height = bounds.frames["header"]?.height ?? 999
        XCTAssertGreaterThan(height, 36)
        XCTAssertLessThanOrEqual(height, 52, "说明文字 must not occupy a row under the title")
        window.isHidden = true
    }

    func testFunctionCardDoesNotScroll() {
        let route = RoutePlaybackController()
        let card = MapHomeBottomCard(
            displayName: "当前选点",
            selectionStatus: "已选位置 · 尚未开始",
            spoofState: .idle, isFavoriteSelected: false, favoriteSaveDisabled: false,
            runtimeStatusText: "开发者模式", runtimeStatusTone: .ok, showsRoute: false,
            showsRouteProgress: false,
            primaryTitle: "连接隧道", primaryAccessibilityLabel: "连接隧道",
            primarySystemImage: nil, primaryColor: .blue, primaryDisabled: false,
            secondaryTitle: nil as String?, secondaryDisabled: false, showsSpotHelp: false,
            availableHeight: AppLayout.homeFunctionCardHeight,
            playbackClock: route.clock,
            spotContent: {
                HomeSpotSwipeLanes(
                    hasRecents: true,
                    favoritesEmpty: false,
                    recentBars: {
                        ForEach(0..<8) { index in
                            Text("最近 \(index)").frame(minWidth: 120, minHeight: 44)
                        }
                    },
                    favoriteBars: {
                        ForEach(0..<8) { index in
                            Text("收藏 \(index)").frame(minWidth: 120, minHeight: 44)
                        }
                    },
                    onClearRecents: {},
                    onManageFavorites: {}
                )
            },
            routePanel: { EmptyView() },
            caption: { EmptyView() },
            onHelp: {}, onToggleFavorite: {}, onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {}
        )
        let host = UIHostingController(rootView: card)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let scrolls = descendants(of: host.view).compactMap { $0 as? UIScrollView }
        XCTAssertFalse(scrolls.filter { $0.contentSize.width > $0.bounds.width + 8 }.isEmpty,
                       "最近/收藏 must swipe horizontally")
        XCTAssertTrue(
            scrolls.allSatisfy { $0.contentSize.height <= $0.bounds.height + 8 },
            "定点功能区 must not scroll vertically"
        )
        window.isHidden = true
    }

    func testSpotSwipeLanesStayInsideTwoRows() {
        let bounds = HomeLayoutBounds()
        let lanes = HomeSpotSwipeLanes(
            hasRecents: true,
            favoritesEmpty: false,
            recentBars: {
                ForEach(0..<6) { index in
                    Text("最近地点 \(index)").frame(minWidth: 140, minHeight: 44)
                }
            },
            favoriteBars: {
                ForEach(0..<6) { index in
                    Text("收藏地点 \(index)").frame(minWidth: 140, minHeight: 44)
                }
            },
            onClearRecents: {},
            onManageFavorites: {}
        )
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { bounds.frames["lanes"] = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { bounds.frames["lanes"] = $0 }
            }
        }
        let host = UIHostingController(rootView: lanes.padding())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertLessThanOrEqual(bounds.frames["lanes"]?.height ?? .infinity, 100)
        let scrolls = descendants(of: host.view).compactMap { $0 as? UIScrollView }
        XCTAssertEqual(scrolls.count, 2)
        XCTAssertTrue(scrolls.allSatisfy { $0.contentSize.width > $0.bounds.width })
        window.isHidden = true
    }

    func testModeEntryPopupStaysInsideTheCardHeight() {
        func render(showPopup: Bool) -> CGFloat {
            let bounds = HomeLayoutBounds()
            let content = VStack(spacing: 8) {
                Text("定点").frame(maxWidth: .infinity, minHeight: 44)
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 200)
                    .overlay {
                        if showPopup {
                            HomePopupSurface(title: "最近地点", onClose: {}, maxHeight: 184) {
                                ForEach(0..<20) { index in
                                    Text("地点 \(index)").frame(minHeight: 44)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onAppear { bounds.frames["card"] = geometry.frame(in: .global) }
                                .onChange(of: geometry.frame(in: .global)) { bounds.frames["card"] = $0 }
                        }
                    }
            }
            .padding()
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { bounds.frames["cluster"] = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { bounds.frames["cluster"] = $0 }
                }
            }
            let host = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let height = bounds.frames["cluster"]?.height ?? -1
            window.isHidden = true
            return height
        }
        let idle = render(showPopup: false)
        let open = render(showPopup: true)
        XCTAssertGreaterThan(idle, 200)
        XCTAssertEqual(idle, open, accuracy: 2, "Opening 最近/收藏 must not grow the function area")
    }

    func testCoordinateMenuListsSystemsAndCopy() {
        let menu = HomeCoordinateMenu(
            selectedSystem: .wgs84, mapSystem: .wgs84, onSelect: { _ in }, onCopy: {}
        )
        let host = UIHostingController(rootView: menu.padding())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let texts = visibleTexts(in: host.view)
        XCTAssertTrue(texts.contains { $0.contains("GCJ-02") }, "got \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("WGS-84") }, "got \(texts)")
        XCTAssertTrue(texts.contains("复制坐标"), "got \(texts)")
        XCTAssertFalse(texts.contains("完成"))
        window.isHidden = true
    }

    func testCoordinateRowPutsFunctionBesideCoordinates() {
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.5, lon: 113.9, mapCoordinateSystem: .wgs84
        )
        let line = MapHomeCoordinateLine(
            pair: pair, mapSystem: .wgs84, selectedSystem: .wgs84,
            showsFunction: true, onCoordinateTap: {}, onFunctionTap: {}
        )
        let host = UIHostingController(rootView: line.padding().frame(width: 390))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 120))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let texts = visibleTexts(in: host.view)
        XCTAssertTrue(texts.contains("功能"), "got \(texts)")
        XCTAssertFalse(texts.contains("走动"), "got \(texts)")
        XCTAssertFalse(texts.contains("参数"), "got \(texts)")
        window.isHidden = true
    }

    func testToolsPopoverOmitsDoneButton() {
        let popover = HomeToolsPopover(title: "真实走动") {
            Toggle(isOn: .constant(false)) { Text("开启") }
        }
        let host = UIHostingController(rootView: popover.padding().frame(width: 360, height: 200))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(visibleTexts(in: host.view).contains("完成"))
        XCTAssertFalse(descendants(of: host.view).compactMap { $0 as? UISwitch }.isEmpty,
                       "function popover must host walk controls")
        window.isHidden = true
    }

    func testWalkPanelUsesShortEnableToggle() {
        let suite = "WalkPanel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhysicalWalkStore(defaults: defaults)
        let walk = PhysicalWalkController()
        let host = UIHostingController(rootView: PhysicalWalkHeadingControls(
            store: store, controller: walk, spoofActive: true
        ).padding())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(descendants(of: host.view).compactMap { $0 as? UISwitch }.isEmpty,
                       "walk panel must keep an enable switch")
        XCTAssertFalse(visibleTexts(in: host.view).contains("完成"))
        XCTAssertTrue(
            visibleTexts(in: host.view).contains("真实走动说明"),
            "walk explanations must sit behind the info control"
        )
        let labels = descendants(of: host.view).compactMap { $0 as? UILabel }.compactMap(\.text)
        XCTAssertFalse(labels.contains { $0.contains("计步器没有距离") })
        XCTAssertFalse(labels.contains { $0.contains("扇形跟系统地图") })
        let switches = descendants(of: host.view).compactMap { $0 as? UISwitch }
        for item in switches {
            let frame = item.convert(item.bounds, to: host.view)
            XCTAssertLessThan(frame.width, 52, "walk switches must stay compact, got \(frame)")
        }
        window.isHidden = true
    }

    func testWalkPanelHugsContentInsteadOfFillingTheCoordinateRow() {
        let suite = "WalkPanelHug.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhysicalWalkStore(defaults: defaults)
        let bounds = HomeLayoutBounds()
        let panel = HomeToolsPopover(compact: true) {
            PhysicalWalkHeadingControls(
                store: store, controller: PhysicalWalkController(), spoofActive: true
            )
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { bounds.frames["walk"] = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { bounds.frames["walk"] = $0 }
            }
        }
        let host = UIHostingController(rootView: panel.frame(maxWidth: 390, maxHeight: 400, alignment: .topTrailing))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let frame = bounds.frames["walk"] ?? .zero
        XCTAssertLessThan(frame.width, 260, "walk popover must hug content, got \(frame)")
        XCTAssertLessThan(frame.height, 80, "closed walk popover must stay a single compact bar, got \(frame)")
        window.isHidden = true
    }

    func testWalkPanelKeepsCompactSlidersWhenEnabled() {
        let suite = "WalkPanelSlider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhysicalWalkStore(defaults: defaults)
        store.setEnabled(true)
        store.setCustomHeadingEnabled(true)
        let bounds = HomeLayoutBounds()
        let panel = HomeToolsPopover(compact: true) {
            PhysicalWalkHeadingControls(
                store: store, controller: PhysicalWalkController(), spoofActive: true
            )
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { bounds.frames["walk"] = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { bounds.frames["walk"] = $0 }
            }
        }
        let host = UIHostingController(rootView: panel.frame(maxWidth: 390, maxHeight: 400, alignment: .topTrailing))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let sliders = descendants(of: host.view).compactMap { $0 as? UISlider }
        XCTAssertGreaterThanOrEqual(sliders.count, 2, "heading and stride must keep sliders")
        XCTAssertLessThan(bounds.frames["walk"]?.width ?? .infinity, 390, "walk toggles must share one compact bar")
        let labels = descendants(of: host.view).compactMap { $0 as? UILabel }.compactMap(\.text)
        XCTAssertTrue(
            visibleTexts(in: host.view).contains { $0.contains("初始指向") },
            "heading lock label must stay on one line, got \(visibleTexts(in: host.view))"
        )
        window.isHidden = true
    }

    func testFunctionPopoverPinsBelowCoordinateRowInsteadOfCentering() {
        let route = RoutePlaybackController()
        route.enter(start: CoordinateConverter.coordinatePair(
            lat: 22.5, lon: 113.9, mapCoordinateSystem: .wgs84
        ))
        let bounds = HomeLayoutBounds()
        let overlay = VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 140)
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: 56)
                HomeToolsPopover(compact: true, hugsHorizontally: false) {
                    RouteParameterControls(route: route, onExit: {}, onSave: {})
                }
                .background(bounds.measure("route"))
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(bounds.measure("overlay"))
        let host = UIHostingController(rootView: overlay.frame(width: 390, height: 852, alignment: .topLeading))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let chrome = bounds.frames["overlay"] ?? .zero
        let panel = bounds.frames["route"] ?? .zero
        XCTAssertGreaterThan(panel.height, 1, "route panel must render, got \(panel)")
        XCTAssertEqual(
            panel.minY, chrome.minY + 140, accuracy: 12,
            "function panel must sit under the coordinate row, overlay=\(chrome) panel=\(panel)"
        )
        XCTAssertLessThan(
            panel.maxY, chrome.minY + 420,
            "function panel must not drop onto the bottom card, overlay=\(chrome) panel=\(panel)"
        )
        window.isHidden = true
    }

    func testRouteParameterPanelOmitsPointOperations() {
        let route = RoutePlaybackController()
        let pair = CoordinateConverter.coordinatePair(
            lat: 22.5, lon: 113.9, mapCoordinateSystem: .wgs84
        )
        route.enter(start: pair)
        route.setEnd(CoordinateConverter.coordinatePair(
            lat: 22.51, lon: 113.91, mapCoordinateSystem: .wgs84
        ))
        let bounds = HomeLayoutBounds()
        let panel = HomeToolsPopover(compact: true, hugsHorizontally: false) {
            RouteParameterControls(route: route, onExit: {}, onSave: {})
        }
        .background(bounds.measure("route"))
        let host = UIHostingController(rootView: panel.frame(maxWidth: 309, maxHeight: 400, alignment: .topLeading))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let texts = visibleTexts(in: host.view)
        XCTAssertTrue(texts.contains("步行"), "route parameters must keep travel modes, got \(texts)")
        XCTAssertTrue(texts.contains("一次"), "route parameters must keep repeat modes, got \(texts)")
        XCTAssertGreaterThanOrEqual(descendants(of: host.view).compactMap { $0 as? UISlider }.count, 2)
        XCTAssertFalse(texts.contains("设为起点"), "route parameters must not repeat point operations, got \(texts)")
        XCTAssertFalse(texts.contains("途经点"), "route parameters must not repeat via actions, got \(texts)")
        XCTAssertFalse(texts.contains("管理与导入路线"), "route parameters must not repeat saved-route management, got \(texts)")
        XCTAssertFalse(texts.contains("完成"), "route parameters must not use a 完成 popup, got \(texts)")
        XCTAssertLessThan(bounds.frames["route"]?.height ?? .infinity, 250, "route popover must stay compact, got \(bounds.frames["route"] ?? .zero)")
        let travel = ["步行", "骑行", "驾车"].compactMap { title in
            descendants(of: host.view).compactMap { $0 as? UIButton }.first { $0.currentTitle == title || $0.accessibilityLabel == title }
        }
        if travel.count == 3 {
            let widths = travel.map { $0.bounds.width }
            XCTAssertEqual(widths[0], widths[1], accuracy: 8, "travel chips must share the row, got \(widths)")
            XCTAssertEqual(widths[1], widths[2], accuracy: 8, "travel chips must share the row, got \(widths)")
        }
        window.isHidden = true
    }

    func testSmallScreenPopupReplacesHeaderInsteadOfLosingItsContent() {
        let regions = MapHomeOverlayRegions(size: CGSize(width: 320, height: 568), safeArea: EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0))
        XCTAssertEqual(regions.top.height, 180)
        XCTAssertEqual(MapHomeOverlayRegions.topHeaderLimit(availableHeight: regions.top.height, measuredHeight: 156, showsPopup: true), 0)
        XCTAssertEqual(MapHomeOverlayRegions.topHeaderLimit(availableHeight: 292, measuredHeight: 156, showsPopup: true), 156)
        XCTAssertEqual(MapHomeOverlayRegions.topHeaderLimit(availableHeight: 292, measuredHeight: 230, showsPopup: true), 0)
        XCTAssertEqual(MapHomeOverlayRegions.topHeaderLimit(availableHeight: 180, measuredHeight: 156, showsPopup: false), 180)
    }

    func testHomeLayouts() {
        let scenarios: [(String, CGSize, Bool, DynamicTypeSize, Bool, Bool)] = [
            ("small-accessibility5", CGSize(width: 320, height: 568), false, .accessibility5, true, true),
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
            if let frame = bounds.frames["bottom"] {
                XCTAssertLessThanOrEqual(frame.height, AppLayout.homeFunctionClusterHeight + 1)
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
                    MapHomeCoordinateLine(
                        pair: pair,
                        mapSystem: .wgs84,
                        selectedSystem: .wgs84,
                        showsFunction: true,
                        onCoordinateTap: {},
                        onFunctionTap: {}
                    )
                }
            }
            .background(measure("top"))
        }, bottom: { height in
            let clusterHeight = min(height, AppLayout.homeFunctionClusterHeight)
            let cardHeight = max(140, clusterHeight - AppLayout.homeModeBarHeight - AppLayout.homeFunctionStackSpacing)
            VStack(spacing: AppLayout.homeFunctionStackSpacing) {
                HStack(spacing: 2) {
                    Button("定点", action: {}).frame(maxWidth: .infinity, minHeight: 44)
                    Button("路线", action: {}).frame(maxWidth: .infinity, minHeight: 44)
                }
                .frame(height: AppLayout.homeModeBarHeight)
                card(availableHeight: cardHeight)
            }
            .frame(height: clusterHeight, alignment: .top)
            .background(measure("bottom"))
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
            secondaryTitle: showsRoute ? "停止" : "停止定位", secondaryDisabled: false, showsSpotHelp: false,
            availableHeight: availableHeight,
            playbackClock: route.clock,
            spotContent: {
                HomeSpotSwipeLanes(
                    hasRecents: true,
                    favoritesEmpty: false,
                    recentBars: {
                        Button("最近地点", action: {}).frame(minWidth: 120, minHeight: 44)
                    },
                    favoriteBars: {
                        Button("收藏地点", action: {}).frame(minWidth: 120, minHeight: 44)
                    },
                    onClearRecents: {},
                    onManageFavorites: {}
                )
            },
            routePanel: {
                HomeRouteSavedList(routes: [], selectedID: nil, onSelect: { _ in }, onManage: {})
            },
            caption: { EmptyView() }, onHelp: {}, onToggleFavorite: {},
            onOpenSettings: {}, onPrimaryTap: {}, onSecondaryTap: {},
            viaTitle: showsRoute ? "途经点" : nil
        )
    }
}

@MainActor
private final class HomeLayoutBounds {
    var frames: [String: CGRect] = [:]

    func measure(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.onAppear { self.frames[key] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { self.frames[key] = $0 }
        }
    }
}
