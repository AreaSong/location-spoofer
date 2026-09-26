import ActivityKit
import AppIntents
import SwiftUI

@available(iOS 16.2, *)
enum IslandLiveButtons {
    static func resolve(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> IslandButtonTriple {
        if state.kind == "spot" {
            return SpotIslandActions.buttons(
                phase: state.phase,
                primaryAction: state.primaryAction,
                primaryTitle: state.primaryTitle,
                secondaryAction: state.secondaryAction,
                secondaryTitle: state.secondaryTitle,
                tertiaryAction: state.tertiaryAction,
                tertiaryTitle: state.tertiaryTitle,
                isStale: isStale
            )
        }
        return RouteIslandActions.buttons(
            phase: state.phase,
            primaryAction: state.primaryAction,
            primaryTitle: state.primaryTitle,
            secondaryAction: state.secondaryAction,
            secondaryTitle: state.secondaryTitle,
            tertiaryAction: state.tertiaryAction,
            tertiaryTitle: state.tertiaryTitle,
            isStale: isStale
        )
    }
}

@available(iOS 16.2, *)
struct IslandLockScreenView: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                IslandExpandedCenter(state: state, isStale: isStale, compact: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    IslandStatusLabel(state: state, isStale: isStale)
                    IslandMetricBlock(state: state, isStale: isStale, compact: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            IslandActionRow(state: state, isStale: isStale, compact: false)
        }
        .padding()
    }
}

@available(iOS 16.2, *)
struct IslandExpandedLeading: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 6) {
            IslandStatusIcon(state: state, isStale: isStale)
            Text(state.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
        .accessibilityLabel(state.title)
    }
}

@available(iOS 16.2, *)
struct IslandExpandedCenter: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool
    var compact = true

    var body: some View {
        if state.kind == "spot" {
            IslandStatusIcon(state: state, isStale: isStale)
                .font(compact ? .title2 : .largeTitle)
        } else {
            IslandProgressRing(
                state: state,
                isStale: isStale,
                showsCaption: false
            )
            .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
        }
    }
}

@available(iOS 16.2, *)
struct IslandExpandedTrailing: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let text = trailingText
        return Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IslandPresentation.warns(state, isStale: isStale) ? Color.orange : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(text)
    }

    private var trailingText: String {
        if state.kind == "spot" {
            return IslandPresentation.displayedStatus(state, isStale: isStale)
        }
        return RouteIslandLayout.compactTrailing(
            phase: state.phase,
            timeText: state.timeText,
            statusText: state.statusText,
            isStale: isStale
        )
    }
}

@available(iOS 16.2, *)
struct IslandExpandedBottom: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandMetricBlock(state: state, isStale: isStale, compact: true)
            IslandActionRow(state: state, isStale: isStale, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.2, *)
struct IslandCompactLeading: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 4) {
            IslandStatusIcon(state: state, isStale: isStale)
            Text(state.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(IslandAccessibility.compactLabel(
            title: state.title,
            status: trailingStatus
        ))
    }

    private var trailingStatus: String {
        if state.kind == "spot" {
            return IslandPresentation.displayedStatus(state, isStale: isStale)
        }
        return RouteIslandLayout.compactTrailing(
            phase: state.phase,
            timeText: state.timeText,
            statusText: state.statusText,
            isStale: isStale
        )
    }
}

@available(iOS 16.2, *)
struct IslandCompactTrailing: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if state.kind != "spot",
           RouteIslandLayout.compactUsesProgressRing(
            phase: state.phase,
            showsProgress: state.showsProgress,
            isStale: isStale
           ) {
            IslandProgressRing(state: state, isStale: isStale, showsCaption: true)
                .frame(width: 22, height: 22)
        } else {
            let text = trailingText
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IslandPresentation.warns(state, isStale: isStale) ? Color.orange : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
                .accessibilityLabel(text)
        }
    }

    private var trailingText: String {
        if state.kind == "spot" {
            return IslandPresentation.displayedStatus(state, isStale: isStale)
        }
        return RouteIslandLayout.compactTrailing(
            phase: state.phase,
            timeText: state.timeText,
            statusText: state.statusText,
            isStale: isStale
        )
    }
}

@available(iOS 16.2, *)
struct IslandProgressRing: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool
    var showsCaption: Bool

    var body: some View {
        let warning = IslandPresentation.warns(state, isStale: isStale)
        let caption = RouteIslandLayout.compactTrailing(
            phase: state.phase,
            timeText: state.timeText,
            statusText: state.statusText,
            isStale: isStale
        )
        ProgressView(value: min(max(state.progress, 0), 1)) {
            if showsCaption {
                Text(caption)
                    .font(.system(size: 8, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .progressViewStyle(.circular)
        .tint(warning ? Color.orange : Color.accentColor)
        .accessibilityLabel(caption)
    }
}

@available(iOS 16.2, *)
struct IslandStatusIcon: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Image(systemName: IslandStalePresentation.usesStaleSymbol(phase: state.phase, isStale: isStale)
            ? "exclamationmark.triangle.fill"
            : symbolName)
            .foregroundStyle(IslandPresentation.warns(state, isStale: isStale) ? Color.orange : Color.primary)
            .accessibilityLabel(IslandPresentation.displayedStatus(state, isStale: isStale))
    }

    private var symbolName: String {
        if state.kind != "spot" {
            return RouteIslandLayout.compactSymbol(
                phase: state.phase,
                modeSymbolName: state.modeSymbolName,
                symbolName: state.symbolName,
                isStale: isStale
            )
        }
        return state.symbolName
    }
}

@available(iOS 16.2, *)
struct IslandStatusLabel: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let status = IslandPresentation.displayedStatus(state, isStale: isStale)
        Text(status)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IslandPresentation.warns(state, isStale: isStale) ? Color.orange : Color.primary)
            .lineLimit(1)
    }
}

@available(iOS 16.2, *)
struct IslandMetricBlock: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool
    var compact: Bool

    var body: some View {
        let metric = metricText
        let warning = IslandPresentation.warns(state, isStale: isStale)
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if state.kind == "spot" {
                if !state.detailText.isEmpty {
                    Text(state.detailText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(metric)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if state.showsProgress, !compact {
                    ProgressView(value: min(max(state.progress, 0), 1))
                        .tint(warning ? Color.orange : Color.accentColor)
                }
            }
            if !state.errorText.isEmpty, state.errorText != metric {
                Text(state.errorText)
                    .font(.subheadline)
                    .foregroundStyle(Color.orange)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(IslandAccessibility.expandedLabel(
            title: "",
            status: "",
            detail: state.kind == "spot" ? state.detailText : metric,
            error: state.errorText == metric ? "" : state.errorText
        ))
    }

    private var metricText: String {
        RouteIslandLayout.metricText(
            phase: state.phase,
            detailText: state.detailText,
            distanceText: state.distanceText,
            timeText: state.timeText,
            statusText: state.statusText,
            speedText: state.speedText
        )
    }
}

@available(iOS 16.2, *)
struct IslandActionRow: View {
    let state: RouteActivityAttributes.ContentState
    let isStale: Bool
    var compact: Bool

    var body: some View {
        let buttons = IslandLiveButtons.resolve(state, isStale: isStale)
        if #available(iOS 17.0, *), !buttons.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(buttons.items.enumerated()), id: \.offset) { index, item in
                    IslandCommandButton(
                        action: IslandActionPresentation.submittedAction(
                            action: item.action,
                            phase: state.phase,
                            retryCommand: state.retryCommand
                        ),
                        title: item.title,
                        prominent: index == 0,
                        compact: compact
                    )
                }
            }
        }
    }
}

@available(iOS 17.0, *)
struct IslandCommandButton: View {
    let action: String
    let title: String
    let prominent: Bool
    let compact: Bool

    var body: some View {
        if action == "openApp" {
            styled(IslandOpenAppIntent())
        } else if commandOpensApp {
            styled(IslandOpeningCommandIntent(action: action))
        } else {
            styled(IslandCommandIntent(action: action))
        }
    }

    private var commandOpensApp: Bool {
        if #available(iOS 26.0, *) {
            return IslandHandoffPolicy.opensAppToDeliver(canContinueInForeground: true)
        }
        return IslandHandoffPolicy.opensAppToDeliver(canContinueInForeground: false)
    }

    @ViewBuilder
    private func styled<I: LiveActivityIntent>(_ intent: I) -> some View {
        let hint = IslandAccessibility.buttonHint(action: action)
        if prominent {
            Button(intent: intent) { buttonTitle }
                .buttonStyle(.borderedProminent)
                .controlSize(compact ? .small : .regular)
                .accessibilityHint(hint)
        } else {
            Button(intent: intent) { buttonTitle }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
                .accessibilityHint(hint)
        }
    }

    private var buttonTitle: some View {
        Text(title)
            .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .frame(minHeight: compact ? 28 : 36)
    }
}

@available(iOS 16.2, *)
enum IslandPresentation {
    static func displayedStatus(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> String {
        IslandStalePresentation.statusText(
            phase: state.phase,
            statusText: state.statusText,
            isStale: isStale
        )
    }

    static func warns(_ state: RouteActivityAttributes.ContentState, isStale: Bool) -> Bool {
        IslandStalePresentation.usesWarningAppearance(
            phase: state.phase,
            isWarning: state.isWarning,
            isStale: isStale
        )
    }
}
