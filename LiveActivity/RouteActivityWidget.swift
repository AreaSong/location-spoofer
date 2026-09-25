import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct RouteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            lockScreen(context.state, isStale: context.isStale)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusLabel(context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    islandBottom(context.state, isStale: context.isStale)
                }
            } compactLeading: {
                statusIcon(context.state, isStale: context.isStale)
            } compactTrailing: {
                compactTrailing(context.state, isStale: context.isStale)
            } minimal: {
                statusIcon(context.state, isStale: context.isStale)
            }
        }
    }

    private func lockScreen(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusLabel(state, isStale: isStale)
            }
            metrics(state, isStale: isStale)
            actionRow(state, isStale: isStale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func islandBottom(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            metrics(state, isStale: isStale)
            actionRow(state, isStale: isStale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func metrics(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        if state.kind == "route" {
            routeMetrics(state, isStale: isStale)
        } else if !state.detailText.isEmpty {
            Text(state.detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if !state.errorText.isEmpty {
            Text(state.errorText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func routeMetrics(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        if state.showsProgress || !state.distanceText.isEmpty || !state.timeText.isEmpty {
            HStack(spacing: 12) {
                if !state.distanceText.isEmpty {
                    Text("剩余 \(state.distanceText)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !state.timeText.isEmpty {
                    Text(state.timeText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            if state.showsProgress {
                ProgressView(value: min(max(state.progress, 0), 1))
                    .tint(isStale || state.isWarning ? Color.orange : Color.accentColor)
            }
        } else if !state.detailText.isEmpty {
            Text(state.detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactTrailing(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        Text(compactText(state, isStale: isStale))
            .foregroundStyle(isStale || state.isWarning ? Color.orange : Color.primary)
    }

    private func compactText(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> String {
        if isStale { return "已中断" }
        switch state.phase {
        case "systemFault", "retrying", "finished", "stopped", "actionFailed":
            return state.statusText
        default:
            break
        }
        if state.kind == "route", !state.timeText.isEmpty { return state.timeText }
        return state.statusText
    }

    private func submittedAction(_ action: String, state: RouteActivityAttributes.ContentState) -> String {
        IslandActionPresentation.submittedAction(
            action: action,
            phase: state.phase,
            retryCommand: state.retryCommand
        )
    }

    private func statusIcon(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        Image(systemName: isStale ? "exclamationmark.triangle.fill" : state.symbolName)
            .foregroundStyle(isStale || state.isWarning ? Color.orange : Color.primary)
    }

    private func statusLabel(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        Text(isStale ? "已中断" : state.statusText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isStale || state.isWarning ? Color.orange : Color.primary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func actionRow(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        let buttons = IslandActionPresentation.buttons(
            phase: state.phase,
            primaryAction: state.primaryAction,
            primaryTitle: state.primaryTitle,
            secondaryAction: state.secondaryAction,
            secondaryTitle: state.secondaryTitle,
            isStale: isStale
        )
        if #available(iOS 17.0, *), !buttons.primaryAction.isEmpty || !buttons.secondaryAction.isEmpty {
            HStack(spacing: 8) {
                if !buttons.primaryAction.isEmpty {
                    Button(intent: IslandActionIntent(action: submittedAction(buttons.primaryAction, state: state))) {
                        Text(buttons.primaryTitle)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !buttons.secondaryAction.isEmpty {
                    Button(intent: IslandActionIntent(action: submittedAction(buttons.secondaryAction, state: state))) {
                        Text(buttons.secondaryTitle)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                }
            }
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
