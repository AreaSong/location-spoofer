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
    case recents, favorites, points, savedRoutes, walk, travel, speed, offset, repetition, management, coordinate
    var id: String { rawValue }
    /// 路线入口打开的列表，叠在底部卡片上，不改变功能区高度。
    var isModeEntry: Bool {
        switch self {
        case .points, .savedRoutes: return true
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
        case .management: return "路线参数"
        case .coordinate: return "坐标标准"
        }
    }
}

enum HomeCoordinateRowFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

enum HomeZoomControlFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 坐标行下方：左边缩放，右边功能浮层，互不遮挡。
enum HomeChromePlacement {
    static let gap: CGFloat = 12

    static func functionLeadingX(coordinateMinX: CGFloat, zoomFrame: CGRect) -> CGFloat {
        let zoomTrailing = zoomFrame.width > 1
            ? zoomFrame.maxX
            : coordinateMinX + AppLayout.mapZoomControlSize
        return zoomTrailing + gap
    }

    static func functionMaxWidth(coordinateMaxX: CGFloat, leadingX: CGFloat, cap: CGFloat) -> CGFloat {
        min(cap, max(120, coordinateMaxX - leadingX))
    }
}

/// 贴在坐标行下的工具浮层，不用「完成」，点空白地图或再点「功能」关掉。
struct HomeToolsPopover<Content: View>: View {
    var title: String? = nil
    var compact = false
    var hugsHorizontally = true
    var maxHeight: CGFloat = 360
    @ViewBuilder let content: () -> Content
    @State private var titleHeight: CGFloat = 24

    var body: some View {
        Group {
            if compact {
                content()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: HomePopoverTitleHeightKey.self, value: geometry.size.height)
                                }
                            }
                    }
                    HomeFittingScrollView(maxHeight: max(44, maxHeight - titleReserve - 28)) {
                        content()
                    }
                }
                .onPreferenceChange(HomePopoverTitleHeightKey.self) { if $0 > 0 { titleHeight = $0 } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 12 : 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: compactCorner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: compactCorner, style: .continuous))
        .shadow(color: .black.opacity(compact ? 0.1 : 0.16), radius: compact ? 6 : 12, y: compact ? 3 : 6)
        .accessibilityIdentifier("home.tools.popover")
        .fixedSize(horizontal: compact && hugsHorizontally, vertical: compact)
    }

    private var titleReserve: CGFloat {
        if let title, !title.isEmpty { return titleHeight }
        return 0
    }

    private var compactCorner: CGFloat {
        compact ? AppRadius.card : AppRadius.control
    }
}

private enum HomePopoverTitleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 坐标标准与复制。不用 SwiftUI Menu，避免叠在 MKMapView 上第二次点击被地图手势吃掉。
struct HomeCoordinateMenu: View {
    let selectedSystem: CoordinateConverter.MapCoordinateSystem
    let mapSystem: CoordinateConverter.MapCoordinateSystem
    let onSelect: (CoordinateConverter.MapCoordinateSystem) -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            systemRow(.gcj02)
            systemRow(.wgs84)
            Button(action: onCopy) {
                Text("复制坐标")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .accessibilityIdentifier("home.coordinate.menu")
    }

    private func systemRow(_ system: CoordinateConverter.MapCoordinateSystem) -> some View {
        let selected = selectedSystem == system
        return Button {
            onSelect(system)
        } label: {
            HStack(spacing: 8) {
                Text(MapHomeCoordinateLine.title(for: system))
                    .font(.subheadline)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if selected && system == mapSystem {
                    Text("当前")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(MapHomeCoordinateLine.title(for: system))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
