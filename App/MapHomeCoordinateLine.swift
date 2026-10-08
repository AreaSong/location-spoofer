import SwiftUI
import UIKit

/// 左边坐标，点开选 GCJ-02 / WGS-84 并复制；首页右边是「功能」。
struct MapHomeCoordinateLine: View {
    let pair: CoordinatePair
    let mapSystem: CoordinateConverter.MapCoordinateSystem
    let selectedSystem: CoordinateConverter.MapCoordinateSystem
    var copied = false
    var showsFunction = false
    var functionSelected = false
    var functionEnabledDot = false
    var functionAccessibilityLabel = "功能"
    var functionAccessibilityValue = ""
    let onCoordinateTap: () -> Void
    var onFunctionTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            coordinateButton
            if showsFunction {
                functionButton
            }
        }
    }

    private var coordinateButton: some View {
        let text = pair.displayLine(for: selectedSystem)
        let isCurrent = selectedSystem == mapSystem
        return Button(action: onCoordinateTap) {
            HStack(spacing: 6) {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(copied ? .green : (isCurrent ? .primary : .secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Text(selectedSystem.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if copied {
                    Text("已复制")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green, in: Capsule())
                } else if isCurrent {
                    Text("当前")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.title(for: selectedSystem)) \(text)")
        .accessibilityHint("打开坐标标准和复制")
        .accessibilityIdentifier("home.coordinate.open")
    }

    private var functionButton: some View {
        Button {
            onFunctionTap?()
        } label: {
            HStack(spacing: 6) {
                if functionEnabledDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text("功能")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(functionSelected ? Color.primary : Color.secondary)
            .background(
                functionSelected
                    ? Color(uiColor: .secondarySystemGroupedBackground)
                    : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(functionAccessibilityLabel)
        .accessibilityValue(functionAccessibilityValue)
        .accessibilityAddTraits(functionSelected ? .isSelected : [])
        .accessibilityIdentifier("home.open.function")
    }

    static func title(for system: CoordinateConverter.MapCoordinateSystem) -> String {
        switch system {
        case .gcj02: return "GCJ-02(国内)"
        case .wgs84: return "WGS-84(国际)"
        }
    }

    static func compactLine(pair: CoordinatePair, mapSystem: CoordinateConverter.MapCoordinateSystem) -> String {
        pair.displayLine(for: mapSystem)
    }

    static func copy(_ pair: CoordinatePair, system: CoordinateConverter.MapCoordinateSystem) {
        UIPasteboard.general.string = pair.displayLine(for: system)
        RuntimeLogger.info("APP", "地图", "已复制坐标", details: [
            "坐标标准": system.diagnosticName
        ])
    }
}

/// 地点详情与真实走动共用底部展开区，不再占据地图顶部。
struct MapHomeLocationDetails: View {
    let pair: CoordinatePair
    let mapSystem: CoordinateConverter.MapCoordinateSystem
    @ObservedObject var walkStore: PhysicalWalkStore
    @ObservedObject var walkController: PhysicalWalkController
    let spoofActive: Bool
    @State private var showsCoordinates = false
    @State private var showsWalk = false
    @State private var selectedSystem: CoordinateConverter.MapCoordinateSystem
    @State private var copied = false
    @State private var showsCoordinateMenu = false
    @State private var copyGeneration = 0

    init(
        pair: CoordinatePair,
        mapSystem: CoordinateConverter.MapCoordinateSystem,
        walkStore: PhysicalWalkStore,
        walkController: PhysicalWalkController,
        spoofActive: Bool
    ) {
        self.pair = pair
        self.mapSystem = mapSystem
        self.walkStore = walkStore
        self.walkController = walkController
        self.spoofActive = spoofActive
        _selectedSystem = State(initialValue: mapSystem)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showsCoordinates) {
                MapHomeCoordinateLine(
                    pair: pair,
                    mapSystem: mapSystem,
                    selectedSystem: selectedSystem,
                    copied: copied,
                    onCoordinateTap: { showsCoordinateMenu.toggle() }
                )
                if showsCoordinateMenu {
                    HomeCoordinateMenu(
                        selectedSystem: selectedSystem,
                        mapSystem: mapSystem,
                        onSelect: { system in
                            selectedSystem = system
                            showsCoordinateMenu = false
                        },
                        onCopy: copySelected
                    )
                }
            } label: {
                Label("选点坐标", systemImage: "location.viewfinder")
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            DisclosureGroup(isExpanded: $showsWalk) {
                PhysicalWalkHeadingControls(store: walkStore, controller: walkController, spoofActive: spoofActive)
            } label: {
                HStack {
                    Label("真实走动", systemImage: "figure.walk")
                    Spacer(minLength: 8)
                    Text(walkStore.isEnabled ? "已开启" : "已关闭")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(minHeight: 44)
            }
        }
        .onChange(of: mapSystem) { selectedSystem = $0 }
        .onChange(of: pair) { _ in selectedSystem = mapSystem }
    }

    private func copySelected() {
        MapHomeCoordinateLine.copy(pair, system: selectedSystem)
        copyGeneration += 1
        let current = copyGeneration
        copied = true
        showsCoordinateMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard copyGeneration == current else { return }
            copied = false
        }
    }
}
