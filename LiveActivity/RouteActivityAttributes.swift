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
        var tertiaryAction: String
        var tertiaryTitle: String
        var phase: String
        var errorText: String
        var retryCommand: String
        var speedText: String

        private enum CodingKeys: String, CodingKey {
            case kind, title, statusText, detailText, distanceText, timeText, progress, showsProgress
            case symbolName, modeSymbolName, isWarning, primaryAction, primaryTitle, secondaryAction, secondaryTitle
            case tertiaryAction, tertiaryTitle, phase, errorText, retryCommand, speedText
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
            tertiaryAction: String = "",
            tertiaryTitle: String = "",
            phase: String = "",
            errorText: String = "",
            retryCommand: String = "",
            speedText: String = ""
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
            self.tertiaryAction = tertiaryAction
            self.tertiaryTitle = tertiaryTitle
            self.phase = phase
            self.errorText = errorText
            self.retryCommand = retryCommand
            self.speedText = speedText
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
            tertiaryAction = try container.decodeIfPresent(String.self, forKey: .tertiaryAction) ?? ""
            tertiaryTitle = try container.decodeIfPresent(String.self, forKey: .tertiaryTitle) ?? ""
            phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
            errorText = try container.decodeIfPresent(String.self, forKey: .errorText) ?? ""
            retryCommand = try container.decodeIfPresent(String.self, forKey: .retryCommand) ?? ""
            speedText = try container.decodeIfPresent(String.self, forKey: .speedText) ?? ""
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
            try container.encode(tertiaryAction, forKey: .tertiaryAction)
            try container.encode(tertiaryTitle, forKey: .tertiaryTitle)
            try container.encode(phase, forKey: .phase)
            try container.encode(errorText, forKey: .errorText)
            try container.encode(retryCommand, forKey: .retryCommand)
            try container.encode(speedText, forKey: .speedText)
        }
    }

    var name: String
}

enum RouteActivityCommandStore {
    static let suiteName = "group.com.paopaolabs.location-spoofer"
    static let pendingKey = "routeActivity.pendingCommand"
    static let pendingAtKey = "routeActivity.pendingCommandAt"
    static let maxAge: TimeInterval = 120

    static var defaults = UserDefaults(suiteName: suiteName) ?? .standard
    static var now: () -> Date = Date.init

    static let allowedActions: Set<String> = [
        "switchHere", "stopSpoof", "retry", "openApp", "pause", "resume", "stopRoute", "play", "begin", "cycleSpeed"
    ]

    static func allows(_ action: String) -> Bool {
        if allowedActions.contains(action) { return true }
        return IslandFavoriteCommand.favoriteID(from: action) != nil
    }

    static let expiredActionKey = "routeActivity.expiredCommand"

    static func enqueue(_ action: String) {
        guard allows(action) else { return }
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
        guard RouteActivityCommandStore.allows(trimmed) else {
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

enum IslandCommandHandoff {
    /// 桥接还没接上时，动作只在队列里。必须把 App 拉到前台，界面注册后再排空。
    static func needsForeground(_ delivery: IslandCommandDelivery) -> Bool {
        delivery == .queued
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
    guard IslandCommandHandoff.needsForeground(delivery) else { return }
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
