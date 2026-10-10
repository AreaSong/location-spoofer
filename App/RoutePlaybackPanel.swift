import SwiftUI

enum RoutePanelSection {
    case summary, points, travel, speed, offset, repetition, management, settings

    init(popup: HomePopup) {
        switch popup {
        case .points: self = .points
        case .travel: self = .travel
        case .speed: self = .speed
        case .offset: self = .offset
        case .repetition: self = .repetition
        case .management: self = .settings
        default: self = .management
        }
    }
}

struct RoutePlaybackPanel: View {
    @ObservedObject var route: RoutePlaybackController
    @ObservedObject var clock: RoutePlaybackClock
    let currentPair: CoordinatePair
    let onExit: () -> Void
    let onSave: () -> Void
    let onOpenSaved: () -> Void
    let onRestart: () -> Void
    var embedded = false
    var section: RoutePanelSection = .summary
    var onSelection: () -> Void = {}
    @State private var customSpeed = false
    @State private var customOffset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch section {
            case .summary: summary
            case .points: points
            case .travel: travelChoices
            case .speed: speedChoices
            case .offset: offsetChoices
            case .repetition: repeatChoices
            case .management: management
            case .settings: settings
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(embedded ? 0 : 10)
        .background {
            if !embedded { RoundedRectangle(cornerRadius: AppRadius.control).fill(.thickMaterial) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = route.pathNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if route.isRouting {
                Text("正在规划路线").font(.caption)
            } else if route.start != nil && route.end != nil {
                Text(distanceLine).font(.caption).foregroundStyle(.secondary)
            }
            if route.interruption == .pushFailed { Button("从头走", action: onRestart).frame(minHeight: 44) }
            if let exceptionStatus { Text(exceptionStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var distanceLine: String {
        if route.phase == .playing || route.phase == .paused {
            return RoutePlayback.formattedRemaining(meters: route.remainingMeters, speedMetersPerSecond: route.speedMetersPerSecond)
        }
        if !route.canPlay { return "起点和终点太近" }
        let meters = route.repeatMode == .roundTrip ? route.distanceMeters * 2 : route.distanceMeters
        let distance = RoutePlayback.formattedDistance(meters)
        let duration = RoutePlayback.formattedDuration(meters: meters, speedMetersPerSecond: route.speedMetersPerSecond)
        switch route.repeatMode {
        case .once: return "\(distance)，\(duration)"
        case .roundTrip: return "往返 \(distance)，\(duration)"
        case .loop: return "\(distance)，循环，\(duration)"
        }
    }

    private var exceptionStatus: String? {
        let text = clock.statusMessage
        guard !text.isEmpty else { return nil }
        switch route.phase {
        case .finished: return text
        case .playing, .paused:
            return text == "已暂停。" || text == route.playbackStatusMessage() ? nil : text
        default: return nil
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("当前地图选点 · 用于设置路线").font(.caption).foregroundStyle(.secondary)
            Text(MapHomeCoordinateLine.compactLine(pair: currentPair, mapSystem: CoordinateConverter.currentMapCoordinateSystem))
                .font(.caption.monospaced()).textSelection(.enabled)
            if route.phase == .preparing {
                operation(route.start == nil ? "设为起点" : "替换起点", symbol: "mappin", value: route.start == nil ? "未设置" : "已设置") {
                    route.setStart(currentPair)
                }
                operation(route.end == nil ? "设为终点" : "替换终点", symbol: "flag", value: route.end == nil ? "未设置" : "已设置") {
                    route.setEnd(currentPair)
                }
                if route.canEditVias {
                    operation("添加途经点", symbol: "plus", value: "已有 \(route.vias.count) 处") { route.addVia(currentPair) }
                }
                if !route.vias.isEmpty {
                    operation("撤销途经点", symbol: "arrow.uturn.backward") { route.removeLastVia() }
                }
            } else {
                Text("运行中用底部「途经点」加绕路；起终点需停止后再改。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if route.phase != .playing && route.canReverse {
                operation("反转路线", symbol: "arrow.left.arrow.right") { route.reverseDirection() }
            }
        }
    }

    private var travelChoices: some View {
        ForEach(Array(RouteTravelMode.allCases), id: \.self) { mode in
            choice(mode.displayName, selected: mode == route.travelMode) { route.applyTravelMode(mode) }
                .disabled(route.locksPathEdits || route.isRouting)
        }
    }

    private var repeatChoices: some View {
        ForEach(Array(RouteRepeatMode.allCases), id: \.self) { mode in
            choice(mode.displayName, selected: mode == route.repeatMode) { route.applyRepeatMode(mode) }
        }
    }

    private var speedChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(route.travelMode.speedPresets, id: \.self) { preset in
                choice(preset.title, selected: abs(route.speedKilometersPerHour - preset.kilometersPerHour) < 0.05) {
                    route.setSpeedKilometersPerHour(preset.kilometersPerHour)
                }
            }
            Button("自定义 · \(RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour))") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    customSpeed.toggle()
                }
            }
            .frame(minHeight: 44)
            if customSpeed || !route.travelMode.speedPresets.contains(where: { abs(route.speedKilometersPerHour - $0.kilometersPerHour) < 0.05 }) {
                Slider(value: Binding(get: { route.speedKilometersPerHour }, set: { route.setSpeedKilometersPerHour($0) }),
                       in: 1...route.travelMode.maximumKilometersPerHour, step: 0.5)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityLabel("自定义速度，公里每小时")
            }
        }
    }

    private var offsetChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([0.0, 15, 30, 50], id: \.self) { meters in
                choice("偏移 \(Int(meters)) 米", selected: abs(route.offsetMeters - meters) < 0.5) { route.setOffsetMeters(meters) }
            }
            Button("自定义 · \(Int(route.offsetMeters.rounded())) 米") {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    customOffset.toggle()
                }
            }
            .frame(minHeight: 44)
            if customOffset || ![0.0, 15, 30, 50].contains(where: { abs(route.offsetMeters - $0) < 0.5 }) {
                Slider(value: Binding(get: { route.offsetMeters }, set: { route.setOffsetMeters($0) }), in: 0...80, step: 5)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityLabel("自定义位置偏移，米")
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            travelChoices
            speedChoices
            repeatChoices
            offsetChoices
            if route.phase != .playing && route.canReverse {
                operation("反转路线", symbol: "arrow.left.arrow.right") { route.reverseDirection() }
            }
            management
        }
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: 0) {
            if route.phase != .playing {
                if route.canPlay && !route.isRouting && !route.waitingForActivation {
                    operation("保存路线", symbol: "square.and.arrow.down", action: onSave)
                }
                operation("管理与导入路线", symbol: "folder", action: onOpenSaved)
            }
            if route.phase == .preparing || route.phase == .finished {
                operation("退出路线", symbol: "xmark.circle", action: onExit)
                    .foregroundStyle(.red)
            }
            if route.phase == .playing || route.phase == .paused {
                Text("停止在底部按钮；退出路线也在这里。").font(.footnote)
                operation("退出路线", symbol: "xmark.circle", action: onExit)
                    .foregroundStyle(.red)
            }
        }
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); onSelection() } label: {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func operation(_ title: String, symbol: String, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button { action(); onSelection() } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer(minLength: 4)
                if let value { Text(value).font(.caption).foregroundStyle(.secondary) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// 路线「功能」浮层：只留参数调节。已存路线、途经点和停止在底部卡片，这里不再重复。
struct RouteParameterControls: View {
    @ObservedObject var route: RoutePlaybackController
    let onExit: () -> Void
    let onSave: () -> Void
    @State private var showsInfo = false
    @State private var barWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            headerRow
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: RouteParamBarWidthKey.self, value: geometry.size.width)
                    }
                }
            if showsInfo {
                Text(Self.infoText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: panelWidth, alignment: .leading)
                    .padding(.vertical, 2)
                    .accessibilityHidden(true)
            }
            chipRow(
                Array(RouteTravelMode.allCases),
                selected: route.travelMode,
                title: \.displayName,
                icon: travelIcon
            ) {
                route.applyTravelMode($0)
            }
            .disabled(route.locksPathEdits || route.isRouting)
            sliderRow(
                icon: "gauge.with.dots.needle.bottom.50percent",
                label: String(format: "%.1f km/h", route.speedKilometersPerHour),
                value: speedBinding,
                range: 1...route.travelMode.maximumKilometersPerHour,
                step: 0.5,
                accessibilityLabel: "速度，公里每小时"
            )
            chipRow(
                Array(RouteRepeatMode.allCases),
                selected: route.repeatMode,
                title: \.displayName,
                icon: repeatIcon
            ) {
                route.applyRepeatMode($0)
            }
            sliderRow(
                icon: "shield.lefthalf.filled",
                label: route.offsetMeters < 0.5 ? "0m" : "±\(Int(route.offsetMeters.rounded()))m",
                value: offsetBinding,
                range: 0...50,
                step: 5,
                accessibilityLabel: "防检测随机位置偏移，米"
            )
            actionRow
        }
        .onPreferenceChange(RouteParamBarWidthKey.self) { if $0 > 1 { barWidth = $0 } }
        .task(id: showsInfo) {
            guard showsInfo else { return }
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            showsInfo = false
        }
    }

    static let infoText = "出行会重新规划路径。速度、重复和偏移立即生效。已存路线在下方卡片里管理。"

    private var panelWidth: CGFloat { max(238, barWidth) }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text("路线参数")
                .font(.subheadline.weight(.semibold))
            Button {
                showsInfo.toggle()
            } label: {
                Image(systemName: showsInfo ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(showsInfo ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("路线参数说明")
            .accessibilityValue(Self.infoText)
            .accessibilityIdentifier("home.route.info")
            Spacer(minLength: 0)
        }
        .frame(width: panelWidth, alignment: .leading)
    }

    private func travelIcon(_ mode: RouteTravelMode) -> String {
        mode.symbolName
    }

    private func repeatIcon(_ mode: RouteRepeatMode) -> String {
        switch mode {
        case .once: return "arrow.right"
        case .roundTrip: return "arrow.left.arrow.right"
        case .loop: return "repeat"
        }
    }

    @ViewBuilder
    private func chipItemView(title: String, icon: String?, isSelected: Bool) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
            }
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private func chipRow<Item: Hashable>(
        _ items: [Item],
        selected: Item,
        title: KeyPath<Item, String>,
        icon: ((Item) -> String)? = nil,
        action: @escaping (Item) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selected
                let itemTitle = item[keyPath: title]
                let iconName = icon?(item)
                Button {
                    Haptics.selection()
                    action(item)
                } label: {
                    chipItemView(title: itemTitle, icon: iconName, isSelected: isSelected)
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
                .accessibilityLabel(itemTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(width: panelWidth)
    }

    private func sliderRow(
        icon: String,
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        accessibilityLabel: String
    ) -> some View {
        Color.clear
            .frame(width: panelWidth, height: 28)
            .overlay {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 14)
                    Slider(value: value, in: range, step: step)
                        .tint(Color.accentColor)
                        .accessibilityLabel(accessibilityLabel)
                    Text(label)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minWidth: 46, alignment: .trailing)
                }
            }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            if route.canReverse {
                Button {
                    Haptics.selection()
                    route.reverseDirection()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("反转")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(HomeInteractiveButtonStyle())
                .accessibilityLabel("反转路线")
            }
            if route.canPlay && !route.isRouting && !route.waitingForActivation && route.phase != .playing {
                Button {
                    Haptics.selection()
                    onSave()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text("保存")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(HomeInteractiveButtonStyle())
                .accessibilityLabel("保存路线")
            }
            Spacer(minLength: 0)
            Button {
                Haptics.warning()
                onExit()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("退出")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.red)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(Color.red.opacity(0.12), in: Capsule())
                .contentShape(Rectangle())
            }
            .buttonStyle(HomeInteractiveButtonStyle())
            .accessibilityLabel("退出路线")
        }
        .frame(width: panelWidth)
        .frame(minHeight: 28)
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { route.speedKilometersPerHour },
            set: { route.setSpeedKilometersPerHour($0) }
        )
    }

    private var offsetBinding: Binding<Double> {
        Binding(
            get: { route.offsetMeters },
            set: { route.setOffsetMeters($0) }
        )
    }
}

private enum RouteParamBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 底部卡片内嵌的沉浸式路线控制面板：出行方式、速度控制、快捷档位、重复模式与防检漂移。
struct RouteCardControls: View {
    @ObservedObject var route: RoutePlaybackController
    let onSave: () -> Void

    @State private var showingCustomSpeedAlert = false
    @State private var customSpeedInputText = ""

    var body: some View {
        VStack(spacing: 5) {
            modeAndActionsRow
            speedSliderRow
            speedPresetsRow
            repeatAndDriftRow
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .alert("自定义时速", isPresented: $showingCustomSpeedAlert) {
            TextField("输入 1 ~ 10000 km/h", text: $customSpeedInputText)
                .keyboardType(.numberPad)
            Button("取消", role: .cancel) { }
            Button("确定") {
                applyCustomSpeedFromInput()
            }
        } message: {
            Text("上限锁定为 10,000 km/h。输入后自动切换至对应标签。")
        }
    }

    private var modeAndActionsRow: some View {
        HStack(spacing: 6) {
            // 出行方式 Segment（步行、骑行、驾车、赛车）
            HStack(spacing: 2) {
                ForEach(RouteTravelMode.allCases) { mode in
                    let isSelected = route.travelMode == mode
                    Button {
                        Haptics.selection()
                        route.applyTravelMode(mode)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: mode.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                            Text(mode.displayName)
                                .font(.caption2.weight(isSelected ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(uiColor: .systemBackground))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(route.locksPathEdits || route.isRouting)

            if route.canReverse {
                Button {
                    Haptics.selection()
                    route.reverseDirection()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("反转")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 7)
                    .frame(minHeight: 26)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(HomeInteractiveButtonStyle())
                .accessibilityLabel("反转路线方向")
            }

            if route.canPlay && !route.isRouting && !route.waitingForActivation && route.phase != .playing {
                Button {
                    Haptics.selection()
                    onSave()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text("保存")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 7)
                    .frame(minHeight: 26)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(HomeInteractiveButtonStyle())
                .accessibilityLabel("保存路线")
            }
        }
    }

    private var speedSliderRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Text("速度")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)
            }
            .frame(width: 44, alignment: .leading)

            if route.travelMode == .racing {
                racingSlider
            } else {
                Slider(
                    value: speedBinding,
                    in: route.travelMode.minimumKilometersPerHour...route.travelMode.maximumKilometersPerHour,
                    step: speedStep(for: route.travelMode)
                )
                .tint(Color.accentColor)
                .accessibilityLabel("路线速度")
            }

            // 点击药丸可调起数字输入弹窗（固定 82x24 尺寸，彻底杜绝变阻器拖动时因文字长短引起的布局呼吸与振荡波动）
            Button {
                Haptics.selection()
                customSpeedInputText = String(format: "%.0f", route.speedKilometersPerHour)
                showingCustomSpeedAlert = true
            } label: {
                HStack(spacing: 2) {
                    Text(formattedSpeedDisplay(route.speedKilometersPerHour))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.60)
                }
                .foregroundStyle(Color.primary)
                .frame(width: 82, height: 24)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("当前时速：\(formattedSpeedDisplay(route.speedKilometersPerHour))，点击输入自定义时速")
        }
        .frame(minHeight: 24)
    }

    private var racingSlider: some View {
        Slider(
            value: racingProgressBinding,
            in: 0...1
        )
        .tint(Color.accentColor)
        .accessibilityLabel("赛车极速滑块，最高10000公里每小时")
    }

    private var speedPresetsRow: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                Image(systemName: "speedometer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Text("档位")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)
            }
            .frame(width: 44, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(route.travelMode.speedPresets, id: \.kilometersPerHour) { preset in
                    let isCurrent = abs(route.speedKilometersPerHour - preset.kilometersPerHour) < 0.5
                    Button {
                        Haptics.selection()
                        route.setSpeedKilometersPerHour(preset.kilometersPerHour)
                    } label: {
                        Text(preset.title)
                            .font(.caption2.weight(isCurrent ? .bold : .medium))
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                            .background {
                                if isCurrent {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.18))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.secondary.opacity(0.08))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.title) 公里每小时")
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
        .frame(minHeight: 22)
    }

    private var repeatAndDriftRow: some View {
        HStack(spacing: 8) {
            // 重复模式
            HStack(spacing: 2) {
                ForEach(RouteRepeatMode.allCases) { mode in
                    let isSelected = route.repeatMode == mode
                    Button {
                        Haptics.selection()
                        route.applyRepeatMode(mode)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: repeatIcon(mode))
                                .font(.system(size: 8, weight: .medium))
                            Text(mode.displayName)
                                .font(.caption2.weight(isSelected ? .semibold : .medium))
                        }
                        .padding(.horizontal, 5)
                        .frame(minHeight: 24)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(uiColor: .systemBackground))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            // 防风控漂移
            HStack(spacing: 3) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
                Text("漂移")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)

                Slider(
                    value: offsetBinding,
                    in: 0...50,
                    step: 5
                )
                .tint(Color.accentColor)
                .accessibilityLabel("防检测随机漂移扰动，米")

                Text(route.offsetMeters < 0.5 ? "0m" : "±\(Int(route.offsetMeters.rounded()))m")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(route.offsetMeters > 0 ? Color.accentColor : Color.primary)
                    .frame(width: 46, height: 22)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .frame(minHeight: 24)
    }

    private func repeatIcon(_ mode: RouteRepeatMode) -> String {
        switch mode {
        case .once: return "arrow.right"
        case .roundTrip: return "arrow.left.arrow.right"
        case .loop: return "repeat"
        }
    }

    private func speedStep(for mode: RouteTravelMode) -> Double {
        switch mode {
        case .walk: return 1.0
        case .bike: return 1.0
        case .drive: return 5.0
        case .racing: return 10.0
        }
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { route.speedKilometersPerHour },
            set: { newValue in
                let step = speedStep(for: route.travelMode)
                let rounded = (newValue / step).rounded() * step
                let clamped = route.travelMode.clampedSpeed(rounded)
                if abs(clamped - route.speedKilometersPerHour) >= (step * 0.4) {
                    route.setSpeedKilometersPerHour(clamped)
                }
            }
        )
    }

    /// 赛车模式非线性对数滑块：10km/h ~ 10000km/h
    /// 在 progress 0.33 处恰好对应 100 km/h，手感细腻灵敏，最高封顶 10000 km/h
    private var racingProgressBinding: Binding<Double> {
        Binding(
            get: {
                let current = max(10, min(RouteTravelMode.absoluteMaxKilometersPerHour, route.speedKilometersPerHour))
                let progress = (log10(current) - 1.0) / 3.0
                return max(0, min(1, progress))
            },
            set: { p in
                let clampedP = max(0, min(1, p))
                let raw = 10.0 * pow(10.0, clampedP * 3.0)
                let rounded: Double
                if raw < 150 {
                    rounded = (raw / 5.0).rounded() * 5.0
                } else if raw < 500 {
                    rounded = (raw / 25.0).rounded() * 25.0
                } else if raw < 2000 {
                    rounded = (raw / 100.0).rounded() * 100.0
                } else {
                    rounded = (raw / 500.0).rounded() * 500.0
                }
                let finalSpeed = min(RouteTravelMode.absoluteMaxKilometersPerHour, max(10, rounded))
                if abs(finalSpeed - route.speedKilometersPerHour) >= 0.5 {
                    route.setSpeedKilometersPerHour(finalSpeed)
                }
            }
        )
    }

    private var offsetBinding: Binding<Double> {
        Binding(
            get: { route.offsetMeters },
            set: { route.setOffsetMeters($0) }
        )
    }

    private func formattedSpeedDisplay(_ speed: Double) -> String {
        if speed >= 1000 || abs(speed - speed.rounded()) < 0.05 {
            return "\(Int(speed.rounded())) km/h"
        }
        return String(format: "%.1f km/h", speed)
    }

    private func applyCustomSpeedFromInput() {
        let trimmed = customSpeedInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value > 0 else { return }
        Haptics.selection()
        route.applySpeedWithAutoMode(value)
    }
}
