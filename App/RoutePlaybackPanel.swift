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
            Button("自定义 · \(RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour))") { customSpeed.toggle() }
                .frame(minHeight: 44)
            if customSpeed || !route.travelMode.speedPresets.contains(where: { abs(route.speedKilometersPerHour - $0.kilometersPerHour) < 0.05 }) {
                Slider(value: Binding(get: { route.speedKilometersPerHour }, set: { route.setSpeedKilometersPerHour($0) }),
                       in: 1...route.travelMode.maximumKilometersPerHour, step: 0.5)
                    .accessibilityLabel("自定义速度，公里每小时")
            }
        }
    }

    private var offsetChoices: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([0.0, 15, 30, 50], id: \.self) { meters in
                choice("偏移 \(Int(meters)) 米", selected: abs(route.offsetMeters - meters) < 0.5) { route.setOffsetMeters(meters) }
            }
            Button("自定义 · \(Int(route.offsetMeters.rounded())) 米") { customOffset.toggle() }.frame(minHeight: 44)
            if customOffset || ![0.0, 15, 30, 50].contains(where: { abs(route.offsetMeters - $0) < 0.5 }) {
                Slider(value: Binding(get: { route.offsetMeters }, set: { route.setOffsetMeters($0) }), in: 0...80, step: 5)
                    .accessibilityLabel("自定义位置偏移，米")
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            points
            travelChoices
            speedChoices
            repeatChoices
            offsetChoices
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
