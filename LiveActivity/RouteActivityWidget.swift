import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct RouteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            expandedBody(context.state)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusLabel(context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBody(context.state)
                }
            } compactLeading: {
                statusIcon(context.state)
            } compactTrailing: {
                statusLabel(context.state)
            } minimal: {
                statusIcon(context.state)
            }
        }
    }

    private func expandedBody(_ state: RouteActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.showsProgress {
                Text(state.detailText)
                    .font(.subheadline)
                ProgressView(value: min(max(state.progress, 0), 1))
                    .tint(state.isWarning ? Color.orange : Color.accentColor)
            }
            actionButton(state)
        }
    }

    private func statusIcon(_ state: RouteActivityAttributes.ContentState) -> some View {
        Image(systemName: state.symbolName)
            .foregroundStyle(state.isWarning ? Color.orange : Color.primary)
    }

    private func statusLabel(_ state: RouteActivityAttributes.ContentState) -> some View {
        Text(state.statusText)
            .foregroundStyle(state.isWarning ? Color.orange : Color.primary)
    }

    @ViewBuilder
    private func actionButton(_ state: RouteActivityAttributes.ContentState) -> some View {
        if #available(iOS 17.0, *), !state.action.isEmpty {
            Button(intent: IslandActionIntent(action: state.action)) {
                Text(state.actionTitle)
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
