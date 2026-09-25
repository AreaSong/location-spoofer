import Foundation

enum RouteActivityPhaseKey: String, Equatable {
    case playing
    case paused
    case warning
    case finished
}

struct RouteActivitySnapshot: Equatable {
    var phaseKey: RouteActivityPhaseKey
    var statusText: String
    var remainingMinutes: Int
    var routeName: String
    var progress: Double
    var distanceText: String
    var timeText: String
    var symbolName: String
    var isWarning: Bool
    var primaryAction: String
    var primaryTitle: String
    var secondaryAction: String
    var secondaryTitle: String
}

enum RouteActivitySync {
    static let userPauseMessage = "已暂停。"
    static let playingStaleInterval: TimeInterval = 45
    static let failureStaleInterval: TimeInterval = 120

    static func staleDate(for snapshot: RouteActivitySnapshot, now: Date = Date()) -> Date? {
        switch snapshot.phaseKey {
        case .playing:
            return now.addingTimeInterval(playingStaleInterval)
        case .warning:
            return now.addingTimeInterval(failureStaleInterval)
        case .paused, .finished:
            return nil
        }
    }

    static func snapshot(
        phase: RoutePhase,
        statusMessage: String,
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        symbolName: String
    ) -> RouteActivitySnapshot? {
        switch phase {
        case .inactive, .preparing:
            return nil
        case .playing:
            return playing(
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress,
                symbolName: symbolName
            )
        case .paused:
            return paused(
                statusMessage: statusMessage,
                routeName: routeName,
                remainingMeters: remainingMeters,
                speedMetersPerSecond: speedMetersPerSecond,
                progress: progress
            )
        case .finished:
            return finished(routeName: routeName, symbolName: symbolName)
        }
    }

    /// 进度不到 1% 时不推送，避免每个定位点都打满灵动岛更新额度。
    static let minimumProgressDelta = 0.01

    static func shouldUpdate(_ previous: RouteActivitySnapshot?, to next: RouteActivitySnapshot) -> Bool {
        guard let previous else { return true }
        if previous.phaseKey != next.phaseKey
            || previous.statusText != next.statusText
            || previous.routeName != next.routeName
            || previous.symbolName != next.symbolName
            || previous.primaryTitle != next.primaryTitle
            || previous.secondaryTitle != next.secondaryTitle
            || previous.distanceText != next.distanceText
            || previous.timeText != next.timeText {
            return true
        }
        return abs(previous.progress - next.progress) >= minimumProgressDelta
    }

    static func remainingMinutes(meters: Double, speedMetersPerSecond: Double) -> Int {
        let seconds = max(meters / max(speedMetersPerSecond, 0.1), 0)
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    private static func playing(
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        symbolName: String
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        return routeSnapshot(
            phaseKey: .playing,
            statusText: "进行中",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: symbolName,
            isWarning: false,
            primaryAction: "pause",
            primaryTitle: "暂停",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线"
        )
    }

    private static func paused(
        statusMessage: String,
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double
    ) -> RouteActivitySnapshot {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        let warning = statusMessage != userPauseMessage && !statusMessage.isEmpty
        if warning {
            return routeSnapshot(
                phaseKey: .warning,
                statusText: "异常",
                minutes: minutes,
                routeName: routeName,
                progress: progress,
                remainingMeters: remainingMeters,
                symbolName: "exclamationmark.triangle.fill",
                isWarning: true,
                primaryAction: "retry",
                primaryTitle: "重试",
                secondaryAction: "openApp",
                secondaryTitle: "打开 App"
            )
        }
        return routeSnapshot(
            phaseKey: .paused,
            statusText: "已暂停",
            minutes: minutes,
            routeName: routeName,
            progress: progress,
            remainingMeters: remainingMeters,
            symbolName: "pause.fill",
            isWarning: false,
            primaryAction: "resume",
            primaryTitle: "继续",
            secondaryAction: "stopRoute",
            secondaryTitle: "停止路线"
        )
    }

    private static func finished(routeName: String, symbolName: String) -> RouteActivitySnapshot {
        routeSnapshot(
            phaseKey: .finished,
            statusText: "已完成",
            minutes: 0,
            routeName: routeName,
            progress: 1,
            remainingMeters: 0,
            symbolName: symbolName,
            isWarning: false,
            primaryAction: "",
            primaryTitle: "",
            secondaryAction: "",
            secondaryTitle: ""
        )
    }

    private static func routeSnapshot(
        phaseKey: RouteActivityPhaseKey,
        statusText: String,
        minutes: Int,
        routeName: String,
        progress: Double,
        remainingMeters: Double,
        symbolName: String,
        isWarning: Bool,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String
    ) -> RouteActivitySnapshot {
        RouteActivitySnapshot(
            phaseKey: phaseKey,
            statusText: statusText,
            remainingMinutes: minutes,
            routeName: routeName,
            progress: progress,
            distanceText: RoutePlayback.formattedDistance(remainingMeters),
            timeText: minutes > 0 ? "\(minutes)分" : "",
            symbolName: symbolName,
            isWarning: isWarning,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle
        )
    }
}

enum SpotActivityStatus: String, Equatable {
    case locating
    case needsSwitch
    case verifying
    case failed
}

struct SpotActivitySnapshot: Equatable {
    var status: SpotActivityStatus
    var placeName: String
    var statusText: String
    var symbolName: String
    var isWarning: Bool
    var caption: String
    var primaryAction: String
    var primaryTitle: String
    var secondaryAction: String
    var secondaryTitle: String
}

enum SpotActivitySync {
    static func snapshot(
        isVerifying: Bool,
        isActive: Bool,
        needsSwitch: Bool,
        failed: Bool,
        placeName: String,
        coordinateStandard: String,
        accuracyMeters: Int
    ) -> SpotActivitySnapshot? {
        let caption = standardCaption(coordinateStandard, accuracyMeters: accuracyMeters)
        if isVerifying {
            return spot(.verifying, placeName: placeName, statusText: "验证中", symbolName: "location", isWarning: false, caption: caption, primaryAction: "", primaryTitle: "", secondaryAction: "", secondaryTitle: "")
        }
        if isActive && needsSwitch {
            return spot(.needsSwitch, placeName: placeName, statusText: "待切换", symbolName: "arrow.triangle.swap", isWarning: false, caption: caption, primaryAction: "switchHere", primaryTitle: "切换到此处", secondaryAction: "stopSpoof", secondaryTitle: "停止虚拟定位")
        }
        if isActive {
            return spot(.locating, placeName: placeName, statusText: "定位中", symbolName: "location.fill", isWarning: false, caption: caption, primaryAction: "stopSpoof", primaryTitle: "停止虚拟定位", secondaryAction: "", secondaryTitle: "")
        }
        if failed {
            return spot(.failed, placeName: placeName, statusText: "未生效", symbolName: "exclamationmark.triangle.fill", isWarning: true, caption: caption, primaryAction: "retry", primaryTitle: "重试", secondaryAction: "openApp", secondaryTitle: "打开 App")
        }
        return nil
    }

    static func shouldUpdate(_ previous: SpotActivitySnapshot?, to next: SpotActivitySnapshot) -> Bool {
        previous != next
    }

    private static func standardCaption(_ standard: String, accuracyMeters: Int) -> String {
        let accuracy = "精度 \(accuracyMeters) 米"
        let trimmed = standard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return accuracy }
        return "\(trimmed) · \(accuracy)"
    }

    private static func spot(
        _ status: SpotActivityStatus,
        placeName: String,
        statusText: String,
        symbolName: String,
        isWarning: Bool,
        caption: String,
        primaryAction: String,
        primaryTitle: String,
        secondaryAction: String,
        secondaryTitle: String
    ) -> SpotActivitySnapshot {
        SpotActivitySnapshot(
            status: status,
            placeName: placeName,
            statusText: statusText,
            symbolName: symbolName,
            isWarning: isWarning,
            caption: caption,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle
        )
    }
}
