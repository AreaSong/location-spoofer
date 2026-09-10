import SwiftUI

struct RoutePlaybackPanel: View {
    @ObservedObject var route: RoutePlaybackController
    let currentPair: CoordinatePair
    let onPlay: () -> Void
    let onExit: () -> Void

    var body: some View {
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
                Button("退出") { onExit() }
                    .font(.footnote.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("速度 \(RoutePlayback.formattedSpeed(kilometersPerHour: route.speedKilometersPerHour))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: speedBinding,
                    in: 1...40,
                    step: 0.5
                )
                .disabled(route.phase == .playing)
                Text(offsetLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: offsetBinding,
                    in: 0...80,
                    step: 5
                )
            }
            switch route.phase {
            case .playing:
                HStack(spacing: 8) {
                    ProgressView(value: route.progress)
                    Button("暂停") { route.pause() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .paused, .finished:
                HStack(spacing: 8) {
                    ProgressView(value: route.progress)
                    playButton
                }
            default:
                HStack(spacing: 8) {
                    Button("起点") { route.setStart(currentPair) }
                        .buttonStyle(.bordered)
                    Button("终点") { route.setEnd(currentPair) }
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    playButton
                }
            }
            if !route.statusMessage.isEmpty {
                Text(route.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private var playButton: some View {
        Button(route.phase == .paused ? "继续走" : "开始走") { onPlay() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!route.canPlay || route.waitingForActivation || route.isRouting)
    }
}
