import SwiftUI

struct RoutePlaybackPanel: View {
    @ObservedObject var route: RoutePlaybackController
    let currentPair: CoordinatePair
    let onPlay: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("直线路线", systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("退出") { onExit() }
                    .font(.footnote.weight(.semibold))
            }
            Text("前台匀速移动。锁屏后会停在最后一个点。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("速度", selection: $route.travelMode) {
                ForEach(RouteTravelMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(route.phase == .playing)
            .onChange(of: route.travelMode) { _ in
                route.refreshReadyMessage()
            }
            HStack(spacing: 8) {
                Button("设为起点") { route.setStart(currentPair) }
                    .buttonStyle(.bordered)
                    .disabled(route.phase == .playing)
                Button("设为终点") { route.setEnd(currentPair) }
                    .buttonStyle(.bordered)
                    .disabled(route.phase == .playing)
            }
            if !route.statusMessage.isEmpty {
                Text(route.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if route.phase == .playing || route.phase == .paused || route.phase == .finished {
                ProgressView(value: route.progress)
            }
            HStack(spacing: 8) {
                if route.phase == .playing {
                    Button("暂停") { route.pause() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(route.phase == .paused ? "继续" : "播放") { onPlay() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!route.canPlay || route.waitingForActivation)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
