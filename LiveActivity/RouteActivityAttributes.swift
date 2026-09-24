import ActivityKit
import AppIntents
import Foundation

@available(iOS 16.2, *)
struct RouteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phaseKey: String
        var statusText: String
        var remainingText: String
        var routeName: String
        var progress: Double
        var symbolName: String
        var isWarning: Bool
        var canToggle: Bool
        var compactTrailing: String
    }

    var routeName: String
}

enum RouteActivityBridge {
    @MainActor static var toggle: (() -> Void)?
}

@available(iOS 17.0, *)
struct ToggleRoutePlaybackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "暂停或继续"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            RouteActivityBridge.toggle?()
        }
        return .result()
    }
}
