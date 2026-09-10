import SwiftUI

struct RoutePlaybackPanel: View {
    @ObservedObject var route: RoutePlaybackController
    let currentPair: CoordinatePair
    let onPlay: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("路线", systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                Picker("速度", selection: $route.travelMode) {
                    ForEach(RouteTravelMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(route.phase == .playing || route.isRouting)
                .onChange(of: route.travelMode) { _ in
                    Task { await route.rebuildPath() }
                }
                Button("退出") { onExit() }
                    .font(.footnote.weight(.semibold))
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

    private var playButton: some View {
        Button(route.phase == .paused ? "继续" : "播放") { onPlay() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!route.canPlay || route.waitingForActivation || route.isRouting)
    }
}
