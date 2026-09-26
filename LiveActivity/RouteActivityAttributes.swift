import ActivityKit
import AppIntents
import Foundation
import os

private let islandCommandLog = Logger(subsystem: "com.paopaolabs.location-spoofer", category: "IslandCommand")

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
        var modeSymbolName: String
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
            case symbolName, modeSymbolName, isWarning, primaryAction, primaryTitle, secondaryAction, secondaryTitle
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
            modeSymbolName: String = "",
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
            self.modeSymbolName = modeSymbolName
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
            modeSymbolName = try container.decodeIfPresent(String.self, forKey: .modeSymbolName) ?? ""
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
            try container.encode(modeSymbolName, forKey: .modeSymbolName)
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
    /// 过期后撤下暂停和停止。用户暂停保留继续，失败态和仍在进行的状态改为重试，并都可以打开 App。
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
        case "finished", "stopped":
            return ("", "", "", "")
        case "userPaused":
            return ("resume", "继续", "openApp", "打开 App")
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

enum SpotIslandActions {
    /// 验证、切换、停止过程中和已停止不留按钮，避免重复点击，也不把终态显示成可继续。
    /// 这些过程过期后只给打开 App，避免在扩展里再发起一次定位。
    static let quietPhases: Set<String> = ["verifying", "switching", "stopping", "stopped"]

    static func buttons(
        phase: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        isStale: Bool
    ) -> (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String) {
        if quietPhases.contains(phase) {
            if !isStale || phase == "stopped" {
                return ("", "", "", "")
            }
            return ("openApp", "打开 App", "", "")
        }
        let presented = IslandActionPresentation.buttons(
            phase: phase,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            isStale: isStale
        )
        guard phase == "locating", !isStale else { return presented }
        return withoutSwitch(presented)
    }

    private static func withoutSwitch(
        _ buttons: (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String)
    ) -> (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String) {
        if buttons.primaryAction == "switchHere" {
            return (buttons.secondaryAction, buttons.secondaryTitle, "", "")
        }
        if buttons.secondaryAction == "switchHere" {
            return (buttons.primaryAction, buttons.primaryTitle, "", "")
        }
        return buttons
    }
}

enum RouteIslandLayout {
    static func metricText(
        phase: String,
        detailText: String,
        distanceText: String,
        timeText: String,
        statusText: String
    ) -> String {
        if !detailText.isEmpty { return detailText }
        if !distanceText.isEmpty, !timeText.isEmpty {
            return "还剩 \(distanceText) · \(timeText)"
        }
        if !distanceText.isEmpty { return "还剩 \(distanceText)" }
        if !timeText.isEmpty { return "还剩 \(timeText)" }
        switch phase {
        case "planning":
            return "正在规划路线"
        case "finished":
            return "已走完"
        case "stopped":
            return "定位仍保持"
        case "retrying":
            return "正在重试"
        case "userPaused":
            return "已暂停"
        case "playing":
            return "正在计算剩余路程"
        default:
            return statusText.isEmpty ? "暂时无法估算剩余路程" : statusText
        }
    }

    static func compactTrailing(timeText: String, statusText: String, isStale: Bool) -> String {
        if isStale { return "已中断" }
        if !timeText.isEmpty { return timeText }
        if !statusText.isEmpty { return statusText }
        return "路线"
    }

    static func compactSymbol(modeSymbolName: String, symbolName: String, isStale: Bool) -> String {
        if isStale { return "exclamationmark.triangle.fill" }
        if !modeSymbolName.isEmpty { return modeSymbolName }
        return symbolName.isEmpty ? "figure.walk" : symbolName
    }
}

enum RouteIslandActions {
    static let quietPhases: Set<String> = ["planning", "retrying", "finished", "stopped"]

    static func buttons(
        phase: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String,
        isStale: Bool
    ) -> (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String) {
        if quietPhases.contains(phase) {
            if !isStale || phase == "finished" || phase == "stopped" {
                return ("", "", "", "")
            }
            if phase == "planning" {
                return ("openApp", "打开 App", "", "")
            }
        }
        let presented = IslandActionPresentation.buttons(
            phase: phase,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle,
            isStale: isStale
        )
        return allowed(presented, phase: phase, isStale: isStale)
    }

    private static func allowed(
        _ buttons: (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String),
        phase: String,
        isStale: Bool
    ) -> (primaryAction: String, primaryTitle: String, secondaryAction: String, secondaryTitle: String) {
        var primary = filter(buttons.primaryAction, title: buttons.primaryTitle, phase: phase, isStale: isStale)
        var secondary = filter(buttons.secondaryAction, title: buttons.secondaryTitle, phase: phase, isStale: isStale)
        if primary.action.isEmpty {
            primary = secondary
            secondary = ("", "")
        }
        if !secondary.action.isEmpty, secondary.action == primary.action {
            secondary = ("", "")
        }
        return (primary.action, primary.title, secondary.action, secondary.title)
    }

    private static func filter(
        _ action: String,
        title: String,
        phase: String,
        isStale: Bool
    ) -> (action: String, title: String) {
        switch action {
        case "pause":
            if isStale || phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            return (action, title.isEmpty ? "暂停" : title)
        case "resume":
            if phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            if isStale, phase != "userPaused" { return ("", "") }
            return (action, "继续")
        case "stopRoute":
            if isStale || phase == "systemFault" || phase == "actionFailed" { return ("", "") }
            return (action, "停止路线")
        case "retry", "openApp":
            return (action, title)
        default:
            return ("", "")
        }
    }
}

enum RouteActivityCommandStore {
    static let suiteName = "group.com.paopaolabs.location-spoofer"
    static let pendingKey = "routeActivity.pendingCommand"
    static let pendingAtKey = "routeActivity.pendingCommandAt"
    static let maxAge: TimeInterval = 120

    static var defaults = UserDefaults(suiteName: suiteName) ?? .standard
    static var now: () -> Date = Date.init

    static let allowedActions: Set<String> = [
        "switchHere", "stopSpoof", "retry", "openApp", "pause", "resume", "stopRoute", "play", "begin"
    ]

    static let expiredActionKey = "routeActivity.expiredCommand"

    static func enqueue(_ action: String) {
        guard allowedActions.contains(action) else { return }
        if let pending = peek(), pending != action {
            islandCommandLog.info(
                "尚未执行的灵动岛动作被新动作替换 \(pending, privacy: .public) -> \(action, privacy: .public)"
            )
        }
        defaults.set(action, forKey: pendingKey)
        defaults.set(now().timeIntervalSince1970, forKey: pendingAtKey)
    }

    static func peek() -> String? {
        defaults.string(forKey: pendingKey)
    }

    static func consume() -> String? {
        guard let action = defaults.string(forKey: pendingKey) else { return nil }
        let storedAt = defaults.object(forKey: pendingAtKey) as? Double
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: pendingAtKey)
        guard let storedAt, now().timeIntervalSince1970 - storedAt <= maxAge else {
            rememberExpired(action)
            return nil
        }
        return action
    }

    static func rememberExpired(_ action: String, log: Bool = true) {
        defaults.set(action, forKey: expiredActionKey)
        if log {
            islandCommandLog.error("灵动岛动作已过期，不会执行 \(action, privacy: .public)")
        }
    }

    static func takeExpiredAction() -> String? {
        guard let action = defaults.string(forKey: expiredActionKey) else { return nil }
        defaults.removeObject(forKey: expiredActionKey)
        return action
    }
}

enum IslandCommandDelivery: Equatable {
    case performed
    case queued
    case rejected
    case duplicate
}

@MainActor
enum RouteActivityBridge {
    static var handler: ((String) -> Void)?
    /// 同一个动作还在处理时，第二次不再转交，避免连点启动两条路线或两次定位。
    static var inFlightAction: String?
    /// 队列里的动作过期后通知界面，避免点击被静默丢掉。
    static var expirationHandler: ((String) -> Void)?

    static func submit(_ action: String) -> IslandCommandDelivery {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RouteActivityCommandStore.allowedActions.contains(trimmed) else {
            islandCommandLog.error("拒绝无效灵动岛动作 \(trimmed, privacy: .public)")
            return .rejected
        }
        if inFlightAction == trimmed {
            islandCommandLog.info("忽略重复灵动岛动作 \(trimmed, privacy: .public)")
            return .duplicate
        }
        RouteActivityCommandStore.enqueue(trimmed)
        guard handler != nil else {
            islandCommandLog.error("灵动岛动作已入队，桥接尚未接上 \(trimmed, privacy: .public)")
            return .queued
        }
        if inFlightAction != nil {
            return .queued
        }
        drainPending()
        return .performed
    }

    static func drainPending() {
        guard handler != nil else { return }
        guard inFlightAction == nil else { return }
        reportExpiredAction()
        guard let action = RouteActivityCommandStore.consume() else {
            reportExpiredAction()
            return
        }
        inFlightAction = action
        handler?(action)
        inFlightAction = nil
        if handler != nil, RouteActivityCommandStore.peek() != nil {
            drainPending()
        }
    }

    private static func reportExpiredAction() {
        guard let action = RouteActivityCommandStore.takeExpiredAction() else { return }
        guard let expirationHandler else {
            RouteActivityCommandStore.rememberExpired(action, log: false)
            return
        }
        expirationHandler(action)
    }
}

enum IslandHandoffPolicy {
    /// 不能把执行交回前台时，只能打开 App。否则进程刚被拉起、界面还没注册桥接，动作会停在队列里直到过期。
    static func opensAppToDeliver(canContinueInForeground: Bool) -> Bool {
        !canContinueInForeground
    }
}

@available(iOS 17.0, *)
struct IslandCommandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "灵动岛操作"
    static var openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    @Parameter(title: "动作")
    var action: String

    init() {
        action = ""
    }

    init(action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        await deliverIslandCommand(action) {
            if #available(iOS 26.0, *) {
                try await self.continueInForeground(
                    IntentDialog("打开 App 以完成这个操作"),
                    alwaysConfirm: false
                )
            }
        }
        return .result()
    }
}

/// iOS 26 之前没有 continueInForeground。这个意图打开 App，让界面注册桥接后再排空队列。
@available(iOS 17.0, *)
struct IslandOpeningCommandIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "灵动岛操作"
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @Parameter(title: "动作")
    var action: String

    init() {
        action = ""
    }

    init(action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        await deliverIslandCommand(action) { }
        return .result()
    }
}

@available(iOS 17.0, *)
private func deliverIslandCommand(
    _ action: String,
    openForeground: () async throws -> Void
) async {
    let delivery = await MainActor.run {
        RouteActivityBridge.submit(action)
    }
    guard delivery == .queued else { return }
    if #available(iOS 26.0, *) {
        do {
            try await openForeground()
        } catch {
            islandCommandLog.error("灵动岛动作无法交回前台 \(action, privacy: .public)")
        }
    }
    await MainActor.run {
        RouteActivityBridge.drainPending()
    }
}

@available(iOS 17.0, *)
struct IslandOpenAppIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "打开 App"
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    func perform() async throws -> some IntentResult {
        let delivery = await MainActor.run {
            RouteActivityBridge.submit("openApp")
        }
        if delivery == .queued {
            await MainActor.run {
                RouteActivityBridge.drainPending()
            }
        }
        return .result()
    }
}
