import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct RouteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            lockScreen(context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    expanded(context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.symbolName)
                    .foregroundStyle(context.state.isWarning ? Color.orange : Color.accentColor)
            } compactTrailing: {
                Text(context.state.compactTrailing)
                    .foregroundStyle(context.state.isWarning ? Color.orange : Color.primary)
            } minimal: {
                Image(systemName: context.state.symbolName)
            }
        }
    }

    private func lockScreen(_ state: RouteActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.routeName)
                .font(.headline)
            Text(state.statusText)
                .font(.subheadline)
                .foregroundStyle(state.isWarning ? Color.orange : Color.secondary)
            progressBar(state)
            toggleButton(state)
        }
        .padding()
    }

    private func expanded(_ state: RouteActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.remainingText)
                .font(.headline)
                .foregroundStyle(state.isWarning ? Color.orange : Color.primary)
            progressBar(state)
            toggleButton(state)
        }
    }

    private func progressBar(_ state: RouteActivityAttributes.ContentState) -> some View {
        ProgressView(value: min(max(state.progress, 0), 1))
            .tint(state.isWarning ? Color.orange : Color.accentColor)
    }

    @ViewBuilder
    private func toggleButton(_ state: RouteActivityAttributes.ContentState) -> some View {
        if #available(iOS 17.0, *), state.canToggle {
            Button(intent: ToggleRoutePlaybackIntent()) {
                Text(state.phaseKey == "paused" ? "继续" : "暂停")
            }
            .buttonStyle(.bordered)
        }
    }
}

@available(iOS 16.2, *)
@main
struct RouteActivityBundle: WidgetBundle {
    var body: some Widget {
        RouteActivityWidget()
    }
}
