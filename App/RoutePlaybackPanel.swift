import SwiftUI

private struct RouteSpeedPreset: Hashable {
    let title: String
    let kilometersPerHour: Double
    static let all = [
        RouteSpeedPreset(title: "3", kilometersPerHour: 3),
        RouteSpeedPreset(title: "5", kilometersPerHour: 5),
        RouteSpeedPreset(title: "8", kilometersPerHour: 8),
        RouteSpeedPreset(title: "15", kilometersPerHour: 15)
    ]
}

private struct RouteOffsetPreset: Hashable {
    let title: String
    let meters: Double
    static let all = [
        RouteOffsetPreset(title: "贴路", meters: 0),
        RouteOffsetPreset(title: "15米", meters: 15),
        RouteOffsetPreset(title: "30米", meters: 30),
        RouteOffsetPreset(title: "50米", meters: 50)
    ]
}

private struct RouteChoiceBar<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    let isSelected: (Item) -> Bool
    var isDisabled = false
    let onSelect: (Item) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onSelect(item)
                } label: {
                    Text(title(item))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(isSelected(item) ? Color.accentColor : Color.primary)
                        .background(
                            isSelected(item) ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
            }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
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
    @State private var showsSpeedOffset = false
    @State private var customSpeed = false
    @State private var customOffset = false

    var body: some View {
        controls
            .padding(embedded ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelChrome)
    }

    @ViewBuilder
    private var panelChrome: some View {
        if !embedded {
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let movementSummary {
                Text(movementSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let notice = route.pathNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            actionRow
            if route.interruption == .pushFailed {
                restartRow
            }
            settingsDisclosure
            if showsSpeedOffset {
                speedOffsetSection
            }
            utilityRow
            if let exceptionStatus {
                Text(exceptionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var movementSummary: String? {
        switch route.phase {
        case .playing, .paused:
            return RoutePlayback.formattedRemaining(
                meters: route.remainingMeters,
                speedMetersPerSecond: route.speedMetersPerSecond
            )
        default:
            return nil
        }
    }

    private var exceptionStatus: String? {
        let text = clock.statusMessage
        guard !text.isEmpty else { return nil }
        switch route.phase {
        case .finished:
            return text
        case .playing, .paused:
            if text == "已暂停。" || text == route.playbackStatusMessage() { return nil }
            return text
        default:
            return nil
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if route.phase == .preparing {
            VStack(alignment: .leading, spacing: 6) {
                Text(preparingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                pinRow
            }
        }
    }

    private var preparingSummary: String {
        if route.isRouting { return "正在规划路线" }
        if route.start == nil { return "先设起点" }
        if route.end == nil {
            return route.vias.isEmpty ? "再设终点" : "已加 \(route.vias.count) 个途经，再设终点"
        }
        if !route.canPlay { return "起点和终点太近" }
        return distanceLine
    }

    private var distanceLine: String {
        let meters = route.distanceMeters
        let duration = RoutePlayback.formattedDuration(
            meters: route.repeatMode == .roundTrip ? meters * 2 : meters,
            speedMetersPerSecond: route.speedMetersPerSecond
        )
        switch route.repeatMode {
        case .once:
            return "\(RoutePlayback.formattedDistance(meters))，\(duration)"
        case .roundTrip:
            return "往返 \(RoutePlayback.formattedDistance(meters * 2))，\(duration)"
        case .loop:
            return "\(RoutePlayback.formattedDistance(meters))，循环，\(duration)"
        }
    }

    private var settingsDisclosure: some View {
        Button {
            showsSpeedOffset.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(routeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: showsSpeedOffset ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("速度与偏移设置")
        .accessibilityValue(routeSummary)
    }

    private var routeSummary: String {
        let speed = RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour)
        let offset = route.offsetMeters <= 0 ? "贴路" : "偏移 \(Int(route.offsetMeters.rounded())) 米"
        return "\(route.travelMode.displayName) · \(speed) · \(offset) · \(route.repeatMode.displayName)"
    }

    private var pinRow: some View {
        HStack(spacing: 6) {
            pinButton(route.start == nil ? "起点" : "起点已设", isSet: route.start != nil) {
                route.setStart(currentPair)
            }
            pinButton(route.end == nil ? "终点" : "终点已设", isSet: route.end != nil) {
                route.setEnd(currentPair)
            }
            pinButton(route.vias.isEmpty ? "途经" : "途经 \(route.vias.count)", isSet: !route.vias.isEmpty, enabled: route.canEditVias) {
                route.addVia(currentPair)
            }
            if !route.vias.isEmpty {
                pinButton("撤销", isSet: false) { route.removeLastVia() }
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    private var restartRow: some View {
        Button("从头走") { onRestart() }
            .buttonStyle(CapsuleChipStyle())
    }

    private func pinButton(
        _ title: String,
        isSet: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(isSet ? Color.accentColor : Color.primary)
                .background(
                    isSet ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppRadius.inset, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    private var utilityRow: some View {
        HStack(spacing: 8) {
            if route.phase != .playing {
                Button("倒着走") { route.reverseDirection() }
                    .buttonStyle(CapsuleChipStyle())
                    .disabled(!route.canReverse)
                Button("保存") { onSave() }
                    .buttonStyle(CapsuleChipStyle())
                    .disabled(!route.canPlay || route.isRouting || route.waitingForActivation)
                Button("已存路线") { onOpenSaved() }
                    .buttonStyle(CapsuleChipStyle())
            }
            Button("退出路线") { onExit() }
                .buttonStyle(CapsuleChipStyle(tint: .red))
            Spacer(minLength: 0)
        }
    }

    private var speedOffsetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RouteChoiceBar(
                items: Array(RouteTravelMode.allCases),
                title: \.displayName,
                isSelected: { $0 == route.travelMode },
                isDisabled: route.locksPathEdits || route.isRouting,
                onSelect: { route.applyTravelMode($0) }
            )
            RouteChoiceBar(
                items: Array(RouteRepeatMode.allCases),
                title: \.displayName,
                isSelected: { $0 == route.repeatMode },
                onSelect: { route.applyRepeatMode($0) }
            )
            metricHeader("速度 km/h", showsCustom: !customSpeed && speedMatchesPreset) {
                customSpeed = true
            }
            RouteChoiceBar(
                items: RouteSpeedPreset.all,
                title: \.title,
                isSelected: { abs(route.speedKilometersPerHour - $0.kilometersPerHour) < 0.05 },
                onSelect: {
                    customSpeed = false
                    route.setSpeedKilometersPerHour($0.kilometersPerHour)
                }
            )
            if customSpeed || !speedMatchesPreset {
                Slider(value: speedBinding, in: 1...40, step: 0.5)
            }
            metricHeader("偏移", showsCustom: !customOffset && offsetMatchesPreset) {
                customOffset = true
            }
            RouteChoiceBar(
                items: RouteOffsetPreset.all,
                title: \.title,
                isSelected: { abs(route.offsetMeters - $0.meters) < 0.5 },
                onSelect: {
                    customOffset = false
                    route.setOffsetMeters($0.meters)
                }
            )
            if customOffset || !offsetMatchesPreset {
                Slider(value: offsetBinding, in: 0...80, step: 5)
            }
        }
    }

    private var speedMatchesPreset: Bool {
        RouteSpeedPreset.all.contains { abs(route.speedKilometersPerHour - $0.kilometersPerHour) < 0.05 }
    }

    private var offsetMatchesPreset: Bool {
        RouteOffsetPreset.all.contains { abs(route.offsetMeters - $0.meters) < 0.5 }
    }

    private func metricHeader(_ title: String, showsCustom: Bool, onCustom: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if showsCustom {
                Button("自定义", action: onCustom)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
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
