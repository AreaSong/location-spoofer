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
                if isCurrent {
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
            .overlay(alignment: .topTrailing) {
                if copied {
                    Text("已复制")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                        .offset(y: -24)
                }
            }
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

/// 搜索栏下方：左边坐标，右边朝向。点坐标可复制并切换坐标系，点朝向可开关走动并改方向。
struct MapHomeTopInfoBar: View {
    let pair: CoordinatePair
    let mapSystem: CoordinateConverter.MapCoordinateSystem
    @ObservedObject var walkStore: PhysicalWalkStore
    @ObservedObject var walkController: PhysicalWalkController
    let spoofActive: Bool
    @State private var showsCoordinates = false
    @State private var showsHeading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                coordinateButton
                headingChip
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(minHeight: 44)

            if showsCoordinates {
                MapHomeCoordinateLine(pair: pair, mapSystem: mapSystem)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            if showsHeading {
                PhysicalWalkHeadingControls(
                    store: walkStore,
                    controller: walkController,
                    spoofActive: spoofActive
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .onAppear { showsHeading = needsHeadingSetup }
        .onChange(of: needsHeadingSetup) { showsHeading = $0 }
    }

    private var needsHeadingSetup: Bool {
        PhysicalWalkHeadingPicker.shouldRevealControls(
            isEnabled: walkStore.isEnabled,
            status: walkController.status,
            hasResolvedHeading: walkController.activeHeadingDegrees != nil,
            followsCompass: walkController.headingMode == .followCompass
        )
    }

    private var coordinateButton: some View {
        Button(action: toggleCoordinates) {
            HStack(spacing: 6) {
                Text(mapSystem.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Text(MapHomeCoordinateLine.compactLine(pair: pair, mapSystem: mapSystem))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Image(systemName: showsCoordinates ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("坐标 \(MapHomeCoordinateLine.compactLine(pair: pair, mapSystem: mapSystem))")
        .accessibilityHint(showsCoordinates ? "收起坐标详情" : "展开坐标详情")
    }

    private var headingChip: some View {
        Button(action: toggleHeading) {
            HStack(spacing: 6) {
                Text(walkStore.isEnabled ? "朝向" : "走动")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(walkStore.isEnabled ? headingSummary : "关")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: showsHeading ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(walkStore.isEnabled ? "朝向 \(headingSummary)" : "真实走动已关")
        .accessibilityHint(showsHeading ? "收起走动与方向" : "展开走动与方向")
    }

    private var headingSummary: String {
        PhysicalWalkHeadingLock.pickerSummary(
            headingDegrees: walkController.activeHeadingDegrees,
            locked: walkController.headingMode.isLocked
        )
    }

    private func toggleCoordinates() {
        showsCoordinates.toggle()
        if showsCoordinates { showsHeading = false }
    }

    private func toggleHeading() {
        showsHeading.toggle()
        if showsHeading { showsCoordinates = false }
    }
}
