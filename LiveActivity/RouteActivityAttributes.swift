import ActivityKit
import AppIntents
import Foundation

@available(iOS 16.2, *)
struct RouteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var kind: String
        var title: String
        var statusText: String
        var detailText: String
        var distanceText: String
        var timeText: String
        var progress: Double
        var showsProgress: Bool
        var symbolName: String
        var isWarning: Bool
        var primaryAction: String
        var primaryTitle: String
        var secondaryAction: String
        var secondaryTitle: String
    }

    var name: String
}

enum RouteActivityCommandStore {
    static let suiteName = "group.com.paopaolabs.location-spoofer"
    static let pendingKey = "routeActivity.pendingCommand"

    static var defaults = UserDefaults(suiteName: suiteName) ?? .standard

    static let allowedActions: Set<String> = [
        "switchHere", "stopSpoof", "retry", "openApp", "pause", "resume", "stopRoute"
    ]

    static func enqueue(_ action: String) {
        guard allowedActions.contains(action) else { return }
        defaults.set(action, forKey: pendingKey)
    }

    static func consume() -> String? {
        guard let action = defaults.string(forKey: pendingKey) else { return nil }
        defaults.removeObject(forKey: pendingKey)
        return action
    }
}

@MainActor
enum RouteActivityBridge {
    static var handler: ((String) -> Void)?

    static func submit(_ action: String) {
        RouteActivityCommandStore.enqueue(action)
        drainPending()
    }

    static func drainPending() {
        guard handler != nil else { return }
        guard let action = RouteActivityCommandStore.consume() else { return }
        handler?(action)
    }
}

@available(iOS 17.0, *)
struct IslandActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "灵动岛操作"
    static var openAppWhenRun = true

    @Parameter(title: "动作")
    var action: String

    init() {
        action = ""
    }

    init(action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        let name = action
        await MainActor.run {
            RouteActivityBridge.submit(name)
        }
        return .result()
    }
}
