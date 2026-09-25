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
        var progress: Double
        var showsProgress: Bool
        var symbolName: String
        var isWarning: Bool
        var showsRoute: Bool
        var action: String
        var actionTitle: String
    }

    var name: String
}

enum RouteActivityCommandStore {
    static let suiteName = "group.com.paopaolabs.location-spoofer"
    static let pendingKey = "routeActivity.pendingCommand"

    static var defaults = UserDefaults(suiteName: suiteName) ?? .standard

    static func enqueue(_ action: String) {
        guard action == "spot" || action == "route" || action == "primary" else { return }
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
    static var showSpot: (() -> Void)?
    static var showRoute: (() -> Void)?
    static var primary: (() -> Void)?

    static func submit(_ action: String) {
        RouteActivityCommandStore.enqueue(action)
        drainPending()
    }

    static func drainPending() {
        guard showSpot != nil, showRoute != nil, primary != nil else { return }
        guard let action = RouteActivityCommandStore.consume() else { return }
        perform(action)
    }

    static func perform(_ action: String) {
        switch action {
        case "spot":
            showSpot?()
        case "route":
            showRoute?()
        case "primary":
            primary?()
        default:
            break
        }
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
