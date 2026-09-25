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
                    if context.state.kind != "spot" {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.kind != "spot" {
                        statusLabel(context.state, isStale: context.isStale)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.kind == "spot" {
                        spotExpanded(context.state, isStale: context.isStale)
                    } else {
                        islandBottom(context.state, isStale: context.isStale)
                    }
                }
            } compactLeading: {
                if context.state.kind == "spot" {
                    spotCompactIdentity(context.state, isStale: context.isStale)
                } else {
                    statusIcon(context.state, isStale: context.isStale)
                }
            } compactTrailing: {
                if context.state.kind == "spot" {
                    spotCompactStatus(context.state, isStale: context.isStale)
                } else {
                    compactTrailing(context.state, isStale: context.isStale)
                }
            } minimal: {
                statusIcon(context.state, isStale: context.isStale)
            }
        }
    }

    @ViewBuilder
    private func lockScreen(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        if state.kind == "spot" {
            spotExpanded(state, isStale: isStale)
        } else {
            routeLockScreen(state, isStale: isStale)
        }
    }

    private func spotExpanded(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            statusLabel(state, isStale: isStale)
            if !state.detailText.isEmpty {
                Text(state.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !state.errorText.isEmpty {
                Text(state.errorText)
                    .font(.subheadline)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            spotActionRow(state, isStale: isStale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spotCompactIdentity(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        HStack(spacing: 4) {
            statusIcon(state, isStale: isStale)
            Text(state.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func spotCompactStatus(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        Text(isStale ? "已中断" : state.statusText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isStale || state.isWarning ? Color.orange : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func spotActionRow(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
        let buttons = SpotIslandActions.buttons(
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
                    spotIslandButton(
                        action: buttons.primaryAction,
                        title: buttons.primaryTitle,
                        state: state,
                        prominent: true
                    )
                }
                if !buttons.secondaryAction.isEmpty {
                    spotIslandButton(
                        action: buttons.secondaryAction,
                        title: buttons.secondaryTitle,
                        state: state,
                        prominent: false
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func spotIslandButton(
        action: String,
        title: String,
        state: RouteActivityAttributes.ContentState,
        prominent: Bool
    ) -> some View {
        if #available(iOS 17.0, *) {
            let submitted = submittedAction(action, state: state)
            if submitted == "openApp" {
                spotOpenAppButton(title: title, prominent: prominent)
            } else {
                spotCommandButton(title: title, action: submitted, prominent: prominent)
            }
        }
    }

    @available(iOS 17.0, *)
    @ViewBuilder
    private func spotOpenAppButton(title: String, prominent: Bool) -> some View {
        if prominent {
            Button(intent: IslandOpenAppIntent()) { spotButtonTitle(title) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(intent: IslandOpenAppIntent()) { spotButtonTitle(title) }
                .buttonStyle(.bordered)
        }
    }

    @available(iOS 17.0, *)
    @ViewBuilder
    private func spotCommandButton(title: String, action: String, prominent: Bool) -> some View {
        if prominent {
            Button(intent: IslandCommandIntent(action: action)) { spotButtonTitle(title) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(intent: IslandCommandIntent(action: action)) { spotButtonTitle(title) }
                .buttonStyle(.bordered)
        }
    }

    private func spotButtonTitle(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
    }

    private func routeLockScreen(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> some View {
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
                    islandButton(
                        action: buttons.primaryAction,
                        title: buttons.primaryTitle,
                        state: state,
                        prominent: true
                    )
                }
                if !buttons.secondaryAction.isEmpty {
                    islandButton(
                        action: buttons.secondaryAction,
                        title: buttons.secondaryTitle,
                        state: state,
                        prominent: false
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func islandButton(
        action: String,
        title: String,
        state: RouteActivityAttributes.ContentState,
        prominent: Bool
    ) -> some View {
        if #available(iOS 17.0, *) {
            let submitted = submittedAction(action, state: state)
            if submitted == "openApp" {
                openAppButton(title: title, prominent: prominent)
            } else {
                commandButton(title: title, action: submitted, prominent: prominent)
            }
        }
    }

    @available(iOS 17.0, *)
    @ViewBuilder
    private func openAppButton(title: String, prominent: Bool) -> some View {
        if prominent {
            Button(intent: IslandOpenAppIntent()) { buttonTitle(title) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(intent: IslandOpenAppIntent()) { buttonTitle(title) }
                .buttonStyle(.bordered)
        }
    }

    @available(iOS 17.0, *)
    @ViewBuilder
    private func commandButton(title: String, action: String, prominent: Bool) -> some View {
        if prominent {
            Button(intent: IslandCommandIntent(action: action)) { buttonTitle(title) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(intent: IslandCommandIntent(action: action)) { buttonTitle(title) }
                .buttonStyle(.bordered)
        }
    }

    private func buttonTitle(_ title: String) -> some View {
        Text(title)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
    }
}

@available(iOS 16.2, *)
@main
struct RouteActivityBundle: WidgetBundle {
    var body: some Widget {
        RouteActivityWidget()
    }
}
