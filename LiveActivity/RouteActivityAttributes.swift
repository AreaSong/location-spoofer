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
        var action: String
        var actionTitle: String
    }

    var name: String
}

enum RouteActivityBridge {
    @MainActor static var pause: (() -> Void)?
    @MainActor static var resume: (() -> Void)?
    @MainActor static var stop: (() -> Void)?
    @MainActor static var switchHere: (() -> Void)?
    @MainActor static var retry: (() -> Void)?
}

@available(iOS 17.0, *)
struct IslandActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "灵动岛操作"
    static var openAppWhenRun = false

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
            switch name {
            case "pause":
                RouteActivityBridge.pause?()
            case "resume":
                RouteActivityBridge.resume?()
            case "stop":
                RouteActivityBridge.stop?()
            case "switch":
                RouteActivityBridge.switchHere?()
            case "retry":
                RouteActivityBridge.retry?()
            default:
                break
            }
        }
        return .result()
    }
}
