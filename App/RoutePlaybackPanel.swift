import SwiftUI

private struct RouteSpeedPreset {
    let title: String
    let kilometersPerHour: Double
    static let all = [
        RouteSpeedPreset(title: "3", kilometersPerHour: 3),
        RouteSpeedPreset(title: "5", kilometersPerHour: 5),
        RouteSpeedPreset(title: "8", kilometersPerHour: 8),
        RouteSpeedPreset(title: "15", kilometersPerHour: 15)
    ]
}

private struct RouteOffsetPreset {
    let title: String
    let meters: Double
    static let all = [
        RouteOffsetPreset(title: "贴路", meters: 0),
        RouteOffsetPreset(title: "15米", meters: 15),
        RouteOffsetPreset(title: "30米", meters: 30),
        RouteOffsetPreset(title: "50米", meters: 50)
    ]
}

struct RoutePlaybackPanel: View {
    @ObservedObject var route: RoutePlaybackController
    @ObservedObject var clock: RoutePlaybackClock
    let currentPair: CoordinatePair
    let onPlay: () -> Void
    let onExit: () -> Void
    let onSave: () -> Void
    let onOpenSaved: () -> Void
    var embedded = false
    @State private var showsSpeedOffset = false

    var body: some View {
        controls
            .padding(embedded ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelChrome)
    }

    @ViewBuilder
    private var panelChrome: some View {
        if embedded {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("走路", systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                Picker("方式", selection: travelModeBinding) {
                    ForEach(RouteTravelMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(route.phase == .playing || route.isRouting)
                Button("已存") { onOpenSaved() }
                    .font(.footnote.weight(.semibold))
                    .disabled(route.phase == .playing)
                Button("退出") { onExit() }
                    .font(.footnote.weight(.semibold))
            }
            Picker("重复", selection: repeatModeBinding) {
                ForEach(RouteRepeatMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            speedOffsetSection
            switch route.phase {
            case .playing:
                HStack(spacing: 8) {
                    ProgressView(value: clock.progress)
                    Button("暂停") { route.pause() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .paused, .finished:
                HStack(spacing: 8) {
                    ProgressView(value: clock.progress)
                    saveButton
                    playButton
                }
            default:
                HStack(spacing: 8) {
                    Button("起点") { route.setStart(currentPair) }
                        .buttonStyle(.bordered)
                    Button("终点") { route.setEnd(currentPair) }
                        .buttonStyle(.bordered)
                    Button("途经") { route.addVia(currentPair) }
                        .buttonStyle(.bordered)
                        .disabled(!route.canEditVias)
                    if !route.vias.isEmpty {
                        Button("撤销") { route.removeLastVia() }
                            .font(.footnote.weight(.semibold))
                    }
                }
                HStack(spacing: 8) {
                    Button("倒着走") { route.reverseDirection() }
                        .font(.footnote.weight(.semibold))
                        .disabled(!route.canReverse)
                    saveButton
                    Spacer(minLength: 0)
                    playButton
                }
            }
            if !clock.statusMessage.isEmpty {
                Text(clock.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var speedOffsetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("速度 km/h").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(RouteSpeedPreset.all, id: \.title) { preset in
                    valueChip(
                        preset.title,
                        selected: abs(route.speedKilometersPerHour - preset.kilometersPerHour) < 0.05,
                        disabled: route.phase == .playing
                    ) {
                        route.setSpeedKilometersPerHour(preset.kilometersPerHour)
                    }
                }
            }
            Text("偏移").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(RouteOffsetPreset.all, id: \.title) { preset in
                    valueChip(
                        preset.title,
                        selected: abs(route.offsetMeters - preset.meters) < 0.5,
                        disabled: false
                    ) {
                        route.setOffsetMeters(preset.meters)
                    }
                }
            }
            Button {
                showsSpeedOffset.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(speedOffsetSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: showsSpeedOffset ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if showsSpeedOffset {
                Text("速度 \(RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: speedBinding, in: 1...40, step: 0.5)
                    .disabled(route.phase == .playing)
                Text(offsetLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: offsetBinding, in: 0...80, step: 5)
            }
        }
    }

    private func valueChip(_ title: String, selected: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var speedOffsetSummary: String {
        "\(RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour)) · \(offsetLabel)"
    }

    private var offsetLabel: String {
        if route.offsetMeters <= 0 {
            return "偏移 0 米，贴着路走"
        }
        return "偏移 \(Int(route.offsetMeters.rounded())) 米"
    }

    private var travelModeBinding: Binding<RouteTravelMode> {
        Binding(
            get: { route.travelMode },
            set: { route.applyTravelMode($0) }
        )
    }

    private var repeatModeBinding: Binding<RouteRepeatMode> {
        Binding(
            get: { route.repeatMode },
            set: { route.applyRepeatMode($0) }
        )
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

    private var saveButton: some View {
        Button("保存") { onSave() }
            .font(.footnote.weight(.semibold))
            .disabled(!route.canPlay || route.isRouting || route.waitingForActivation)
    }

    private var playButton: some View {
        Button(route.phase == .paused ? "继续走" : "开始走") { onPlay() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!route.canPlay || route.waitingForActivation || route.isRouting)
    }
}
