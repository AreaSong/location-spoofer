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
                    expandedControls(context.state)
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
        expandedControls(state)
    }

    private func expandedControls(_ state: RouteActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                modeChip("定点", selected: !state.showsRoute, action: "spot")
                modeChip("走路", selected: state.showsRoute, action: "route")
            }
            if state.showsProgress {
                ProgressView(value: min(max(state.progress, 0), 1))
                    .tint(state.isWarning ? Color.orange : Color.accentColor)
            }
            actionButton(state)
            if !state.detailText.isEmpty {
                Text(state.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func modeChip(_ title: String, selected: Bool, action: String) -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: IslandActionIntent(action: action)) {
                chipLabel(title, selected: selected)
            }
            .buttonStyle(.plain)
        } else {
            chipLabel(title, selected: selected)
        }
    }

    private func chipLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
            Button(intent: IslandActionIntent(action: "primary")) {
                Text(state.actionTitle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.borderedProminent)
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
