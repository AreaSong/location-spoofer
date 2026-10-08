import SwiftUI

/// 与地图同一坐标空间划分可用区域，中心 120pt 加两侧 16pt 留白不承载控件。
struct MapHomeOverlayRegions {
    let top: CGRect
    let bottom: CGRect
    let protectedCenter: CGRect

    /// 空间不足时让浮窗临时使用整个顶部区域，保证标题和至少一行内容可操作。
    static func topHeaderLimit(availableHeight: CGFloat, measuredHeight: CGFloat, showsPopup: Bool) -> CGFloat {
        guard showsPopup else { return availableHeight }
        return availableHeight - measuredHeight >= 134 ? measuredHeight : 0
    }

    init(size: CGSize, safeArea: EdgeInsets = EdgeInsets()) {
        let gap: CGFloat = 76
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        protectedCenter = CGRect(x: center.x - gap, y: center.y - gap, width: gap * 2, height: gap * 2)
        let left = safeArea.leading + 12
        let right = size.width - safeArea.trailing - 12
        let upper = safeArea.top + 8
        let lower = size.height - safeArea.bottom - 8
        if size.width > size.height {
            top = CGRect(x: left, y: upper, width: max(0, center.x - gap - left), height: max(0, lower - upper))
            bottom = CGRect(x: center.x + gap, y: upper, width: max(0, right - center.x - gap), height: max(0, lower - upper))
        } else {
            top = CGRect(x: left, y: upper, width: max(0, right - left), height: max(0, center.y - gap - upper))
            bottom = CGRect(x: left, y: center.y + gap, width: max(0, right - left), height: max(0, lower - center.y - gap))
        }
    }
}

struct MapHomeOverlayLayout<Top: View, Bottom: View>: View {
    @ViewBuilder let top: (CGFloat) -> Top
    @ViewBuilder let bottom: (CGFloat) -> Bottom

    var body: some View {
        GeometryReader { geometry in
            let safe = geometry.safeAreaInsets
            let size = CGSize(width: geometry.size.width + safe.leading + safe.trailing,
                              height: geometry.size.height + safe.top + safe.bottom)
            let regions = MapHomeOverlayRegions(size: size, safeArea: safe)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    top(regions.top.height)
                        .frame(width: regions.top.width, alignment: .top)
                    Spacer(minLength: 0).allowsHitTesting(false)
                }
                .frame(width: regions.top.width, height: regions.top.height, alignment: .top)
                .clipped()
                .offset(x: regions.top.minX, y: regions.top.minY)
                VStack(spacing: 0) {
                    Spacer(minLength: 0).allowsHitTesting(false)
                    bottom(regions.bottom.height)
                        .frame(width: regions.bottom.width, alignment: .bottom)
                }
                .frame(width: regions.bottom.width, height: regions.bottom.height, alignment: .bottom)
                .offset(x: regions.bottom.minX, y: regions.bottom.minY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .offset(x: -safe.leading, y: -safe.top)
        }
    }
}

/// 内容短时贴合内容，内容长时只在所属区域滚动；需要撑满时用 fillsMaxHeight 锁死高度。
struct HomeFittingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    var fillsMaxHeight: Bool = false
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: HomeScrollHeightKey.self, value: geometry.size.height)
                    }
                }
        }
        .onPreferenceChange(HomeScrollHeightKey.self) { contentHeight = $0 }
        .frame(height: fillsMaxHeight ? max(0, maxHeight) : min(contentHeight > 0 ? contentHeight : maxHeight, max(0, maxHeight)))
        .clipped()
    }
}

private enum HomeScrollHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum HomePopup: String, Identifiable {
    case recents, favorites, points, savedRoutes, walk, travel, speed, offset, repetition, management
    var id: String { rawValue }
    /// 定点/路线入口打开的列表，叠在底部卡片上，不改变功能区高度。
    var isModeEntry: Bool {
        switch self {
        case .recents, .favorites, .points, .savedRoutes: return true
        default: return false
        }
    }
    var isRouteParameter: Bool {
        switch self {
        case .travel, .speed, .offset, .repetition, .management: return true
        default: return false
        }
    }
    var title: String {
        switch self {
        case .recents: return "最近地点"
        case .favorites: return "收藏地点"
        case .points: return "路线点位"
        case .savedRoutes: return "已存路线"
        case .walk: return "真实走动"
        case .travel: return "出行方式"
        case .speed: return "速度"
        case .offset: return "位置偏移"
        case .repetition: return "重复方式"
        case .management: return "路线管理"
        }
    }
}

struct HomePopupSurface<Content: View>: View {
    let title: String
    let onClose: () -> Void
    var maxHeight: CGFloat? = nil
    @ViewBuilder let content: () -> Content
    @State private var headerHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button("完成", action: onClose).fixedSize().frame(minWidth: 44, minHeight: 44)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: HomePopupHeaderHeightKey.self, value: geometry.size.height)
                }
            }
            if let maxHeight {
                HomeFittingScrollView(maxHeight: maxHeight - headerHeight - 12) { content() }
            } else {
                content()
            }
        }
        .onPreferenceChange(HomePopupHeaderHeightKey.self) { if $0 > 0 { headerHeight = $0 } }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AppRadius.control))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control))
        .accessibilityIdentifier("home.popup")
    }
}

private enum HomePopupHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
