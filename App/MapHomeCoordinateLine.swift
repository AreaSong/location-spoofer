import SwiftUI

/// 切换 GCJ-02 / WGS-84，点数字复制。
struct MapHomeCoordinateLine: View {
    let pair: CoordinatePair
    let mapSystem: CoordinateConverter.MapCoordinateSystem
    @State private var selectedSystem: CoordinateConverter.MapCoordinateSystem

    init(pair: CoordinatePair, mapSystem: CoordinateConverter.MapCoordinateSystem) {
        self.pair = pair
        self.mapSystem = mapSystem
        _selectedSystem = State(initialValue: mapSystem)
    }

    var body: some View {
        HStack(spacing: 8) {
            systemSwitcher
            coordinateCopy
        }
        .onChange(of: mapSystem) { selectedSystem = $0 }
        .onChange(of: pair) { _ in selectedSystem = mapSystem }
    }

    private var systemSwitcher: some View {
        HStack(spacing: 2) {
            systemChip(.gcj02)
            systemChip(.wgs84)
        }
        .padding(2)
        .background(
            Color.secondary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
        )
    }

    private func systemChip(_ system: CoordinateConverter.MapCoordinateSystem) -> some View {
        let selected = selectedSystem == system
        return Button {
            selectedSystem = system
        } label: {
            Text(system.rawValue)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.title(for: system))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var coordinateCopy: some View {
        let coordinate = pair.coordinate(for: selectedSystem)
        let text = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        let isCurrent = selectedSystem == mapSystem
        return CopyButton(value: {
            RuntimeLogger.info("APP", "地图", "已复制坐标", details: [
                "坐标标准": selectedSystem.diagnosticName
            ])
            return text
        }) { copied in
            HStack(spacing: 6) {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(copied ? .green : (isCurrent ? .primary : .secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .layoutPriority(1)
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
        .accessibilityHint("点击复制")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showsCoordinates) {
                MapHomeCoordinateLine(pair: pair, mapSystem: mapSystem)
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
    }
}
