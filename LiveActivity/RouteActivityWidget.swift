import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct RouteActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            IslandLockScreenView(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpandedLeading(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandExpandedCenter(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpandedTrailing(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpandedBottom(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                IslandCompactLeading(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                IslandCompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                IslandStatusIcon(state: context.state, isStale: context.isStale)
            }
            .keylineTint(
                IslandPresentation.warns(context.state, isStale: context.isStale)
                    ? Color.orange
                    : Color.cyan
            )
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
