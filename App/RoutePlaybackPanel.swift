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
    let onPlay: () -> Void
    let onExit: () -> Void
    let onSave: () -> Void
    let onOpenSaved: () -> Void
    var embedded = false
    @State private var showsSpeedOffset = false

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
            actionRow
            settingsDisclosure
            if showsSpeedOffset {
                speedOffsetSection
            }
            utilityRow
            // 长引导只出现在展开区。收起态用卡片上的一行摘要，这里不再重复。
            if route.phase != .preparing {
                statusMessage
            }
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if !clock.statusMessage.isEmpty {
            Text(clock.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch route.phase {
        case .playing:
            VStack(spacing: 6) {
                ProgressView(value: clock.progress)
                primaryButton("暂停", disabled: false) { route.pause() }
            }
        case .paused, .finished:
            VStack(spacing: 6) {
                ProgressView(value: clock.progress)
                primaryButton(route.phase == .paused ? "继续走" : "开始走", disabled: playDisabled) { onPlay() }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                statusMessage
                pinRow
                primaryButton("开始走", disabled: playDisabled) { onPlay() }
            }
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
            Button("起点") { route.setStart(currentPair) }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            Button("终点") { route.setEnd(currentPair) }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            Button("途经") { route.addVia(currentPair) }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .disabled(!route.canEditVias)
                .opacity(route.canEditVias ? 1 : 0.4)
            if !route.vias.isEmpty {
                Button("撤销") { route.removeLastVia() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
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
                Button("已存") { onOpenSaved() }
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
                isDisabled: route.phase == .playing || route.isRouting,
                onSelect: { route.applyTravelMode($0) }
            )
            RouteChoiceBar(
                items: Array(RouteRepeatMode.allCases),
                title: \.displayName,
                isSelected: { $0 == route.repeatMode },
                onSelect: { route.applyRepeatMode($0) }
            )
            Text("速度 km/h")
                .font(.caption)
                .foregroundStyle(.secondary)
            RouteChoiceBar(
                items: RouteSpeedPreset.all,
                title: \.title,
                isSelected: { abs(route.speedKilometersPerHour - $0.kilometersPerHour) < 0.05 },
                isDisabled: route.phase == .playing,
                onSelect: { route.setSpeedKilometersPerHour($0.kilometersPerHour) }
            )
            Slider(value: speedBinding, in: 1...40, step: 0.5)
                .disabled(route.phase == .playing)
            Text("偏移")
                .font(.caption)
                .foregroundStyle(.secondary)
            RouteChoiceBar(
                items: RouteOffsetPreset.all,
                title: \.title,
                isSelected: { abs(route.offsetMeters - $0.meters) < 0.5 },
                onSelect: { route.setOffsetMeters($0.meters) }
            )
            Slider(value: offsetBinding, in: 0...80, step: 5)
        }
    }

    private func primaryButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "figure.walk")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionStyle(compact: true))
        .disabled(disabled)
    }

    private var playDisabled: Bool {
        !route.canPlay || route.waitingForActivation || route.isRouting
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
