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
        var phase: String
        var errorText: String
        var retryCommand: String

        private enum CodingKeys: String, CodingKey {
            case kind, title, statusText, detailText, distanceText, timeText, progress, showsProgress
            case symbolName, isWarning, primaryAction, primaryTitle, secondaryAction, secondaryTitle
            case phase, errorText, retryCommand
        }

        init(
            kind: String,
            title: String,
            statusText: String,
            detailText: String,
            distanceText: String,
            timeText: String,
            progress: Double,
            showsProgress: Bool,
            symbolName: String,
            isWarning: Bool,
            primaryAction: String,
            primaryTitle: String,
            secondaryAction: String,
            secondaryTitle: String,
            phase: String = "",
            errorText: String = "",
            retryCommand: String = ""
        ) {
            self.kind = kind
            self.title = title
            self.statusText = statusText
            self.detailText = detailText
            self.distanceText = distanceText
            self.timeText = timeText
            self.progress = progress
            self.showsProgress = showsProgress
            self.symbolName = symbolName
            self.isWarning = isWarning
            self.primaryAction = primaryAction
            self.primaryTitle = primaryTitle
            self.secondaryAction = secondaryAction
            self.secondaryTitle = secondaryTitle
            self.phase = phase
            self.errorText = errorText
            self.retryCommand = retryCommand
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            title = try container.decode(String.self, forKey: .title)
            statusText = try container.decode(String.self, forKey: .statusText)
            detailText = try container.decode(String.self, forKey: .detailText)
            distanceText = try container.decode(String.self, forKey: .distanceText)
            timeText = try container.decode(String.self, forKey: .timeText)
            progress = try container.decode(Double.self, forKey: .progress)
            showsProgress = try container.decode(Bool.self, forKey: .showsProgress)
            symbolName = try container.decode(String.self, forKey: .symbolName)
            isWarning = try container.decode(Bool.self, forKey: .isWarning)
            primaryAction = try container.decode(String.self, forKey: .primaryAction)
            primaryTitle = try container.decode(String.self, forKey: .primaryTitle)
            secondaryAction = try container.decode(String.self, forKey: .secondaryAction)
            secondaryTitle = try container.decode(String.self, forKey: .secondaryTitle)
            phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
            errorText = try container.decodeIfPresent(String.self, forKey: .errorText) ?? ""
            retryCommand = try container.decodeIfPresent(String.self, forKey: .retryCommand) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(statusText, forKey: .statusText)
            try container.encode(detailText, forKey: .detailText)
            try container.encode(distanceText, forKey: .distanceText)
            try container.encode(timeText, forKey: .timeText)
            try container.encode(progress, forKey: .progress)
            try container.encode(showsProgress, forKey: .showsProgress)
            try container.encode(symbolName, forKey: .symbolName)
            try container.encode(isWarning, forKey: .isWarning)
            try container.encode(primaryAction, forKey: .primaryAction)
            try container.encode(primaryTitle, forKey: .primaryTitle)
            try container.encode(secondaryAction, forKey: .secondaryAction)
            try container.encode(secondaryTitle, forKey: .secondaryTitle)
            try container.encode(phase, forKey: .phase)
            try container.encode(errorText, forKey: .errorText)
            try container.encode(retryCommand, forKey: .retryCommand)
        }
    }

    var name: String
}

enum IslandActionPresentation {
    /// 过期后撤下暂停、继续、停止和切换。失败态和仍在进行的状态改为重试加打开 App。
    static func buttons(
        phase: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        isStale: Bool
    ) -> (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String) {
        if !isStale {
            return (primaryAction, primaryTitle, secondaryAction, secondaryTitle)
        }
        switch phase {
        case "userPaused", "finished", "stopped":
            return ("", "", "", "")
        default:
            return ("retry", "重试", "openApp", "打开 App")
        }
    }

    /// 没有记下失败命令时，按当前阶段重试，避免进行中的重试落到停止定位。
    static func submittedAction(action: String, phase: String, retryCommand: String) -> String {
        guard action == "retry" else { return action }
        if !retryCommand.isEmpty { return retryCommand }
        switch phase {
        case "playing", "retrying":
            return "play"
        case "needsSwitch":
            return "switchHere"
        case "stopping":
            return "stopSpoof"
        case "locating", "verifying", "switching":
            return "begin"
        default:
            return action
        }
    }
}

enum RouteActivityCommandStore {
    static let suiteName = "group.com.paopaolabs.location-spoofer"
    static let pendingKey = "routeActivity.pendingCommand"

    static var defaults = UserDefaults(suiteName: suiteName) ?? .standard

    static let allowedActions: Set<String> = [
        "switchHere", "stopSpoof", "retry", "openApp", "pause", "resume", "stopRoute", "play", "begin"
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
