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
    var detailText: String
    var symbolName: String
    var isWarning: Bool
    var showsRoute: Bool
    var action: String
    var actionTitle: String
}

enum RouteActivitySync {
    static let userPauseMessage = "已暂停。"

    static func snapshot(
        phase: RoutePhase,
        statusMessage: String,
        routeName: String,
        remainingMeters: Double,
        speedMetersPerSecond: Double,
        progress: Double,
        symbolName: String
    ) -> RouteActivitySnapshot? {
        let minutes = remainingMinutes(meters: remainingMeters, speedMetersPerSecond: speedMetersPerSecond)
        let detail = "还剩 \(RoutePlayback.formattedDistance(remainingMeters))"
        switch phase {
        case .inactive, .preparing:
            return nil
        case .playing:
            return routeSnapshot(
                phaseKey: .playing,
                statusText: "\(minutes)分",
                minutes: minutes,
                routeName: routeName,
                progress: progress,
                detailText: detail,
                symbolName: symbolName,
                isWarning: false,
                action: "primary",
                actionTitle: "暂停"
            )
        case .paused:
            let warning = statusMessage != userPauseMessage && !statusMessage.isEmpty
            if warning {
                return routeSnapshot(
                    phaseKey: .warning,
                    statusText: "异常",
                    minutes: minutes,
                    routeName: routeName,
                    progress: progress,
                    detailText: detail,
                    symbolName: "exclamationmark.triangle.fill",
                    isWarning: true,
                    action: "",
                    actionTitle: ""
                )
            }
            return routeSnapshot(
                phaseKey: .paused,
                statusText: "暂停",
                minutes: minutes,
                routeName: routeName,
                progress: progress,
                detailText: detail,
                symbolName: "pause.fill",
                isWarning: false,
                action: "primary",
                actionTitle: "继续"
            )
        case .finished:
            return routeSnapshot(
                phaseKey: .finished,
                statusText: "完成",
                minutes: 0,
                routeName: routeName,
                progress: 1,
                detailText: detail,
                symbolName: "checkmark.circle.fill",
                isWarning: false,
                action: "",
                actionTitle: ""
            )
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
            || previous.actionTitle != next.actionTitle
            || previous.detailText != next.detailText {
            return true
        }
        return abs(previous.progress - next.progress) >= minimumProgressDelta
    }

    static func preparingSnapshot(
        routeName: String,
        hasStart: Bool,
        hasEnd: Bool,
        canPlay: Bool,
        isRouting: Bool,
        distanceMeters: Double,
        symbolName: String
    ) -> RouteActivitySnapshot {
        let statusText: String
        let actionTitle: String
        let detailText: String
        if isRouting {
            statusText = "规划中"
            actionTitle = ""
            detailText = "正在规划路线"
        } else if !hasStart {
            statusText = "设起点"
            actionTitle = "设为起点"
            detailText = "先设起点"
        } else if !hasEnd || !canPlay {
            statusText = "设终点"
            actionTitle = "设为终点"
            detailText = "再设终点"
        } else {
            statusText = "开始走"
            actionTitle = "开始走"
            detailText = RoutePlayback.formattedDistance(distanceMeters)
        }
        return routeSnapshot(
            phaseKey: .playing,
            statusText: statusText,
            minutes: 0,
            routeName: routeName,
            progress: 0,
            detailText: detailText,
            symbolName: symbolName,
            isWarning: false,
            action: actionTitle.isEmpty ? "" : "primary",
            actionTitle: actionTitle
        )
    }

    private static func routeSnapshot(
        phaseKey: RouteActivityPhaseKey,
        statusText: String,
        minutes: Int,
        routeName: String,
        progress: Double,
        detailText: String,
        symbolName: String,
        isWarning: Bool,
        action: String,
        actionTitle: String
    ) -> RouteActivitySnapshot {
        RouteActivitySnapshot(
            phaseKey: phaseKey,
            statusText: statusText,
            remainingMinutes: minutes,
            routeName: routeName,
            progress: progress,
            detailText: detailText,
            symbolName: symbolName,
            isWarning: isWarning,
            showsRoute: true,
            action: action,
            actionTitle: actionTitle
        )
    }

    static func remainingMinutes(meters: Double, speedMetersPerSecond: Double) -> Int {
        let seconds = max(meters / max(speedMetersPerSecond, 0.1), 0)
        return max(1, Int((seconds / 60).rounded(.up)))
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
    var showsRoute: Bool
    var caption: String
    var action: String
    var actionTitle: String
}

enum SpotActivitySync {
    static func snapshot(
        isVerifying: Bool,
        isActive: Bool,
        needsSwitch: Bool,
        failed: Bool,
        placeName: String,
        buttonTitle: String
    ) -> SpotActivitySnapshot? {
        if isVerifying {
            return spot(.verifying, placeName: placeName, statusText: "验证中", symbolName: "location", isWarning: false, caption: "正在检测", action: "", actionTitle: "")
        }
        if isActive && needsSwitch {
            return spot(.needsSwitch, placeName: placeName, statusText: "待切换", symbolName: "arrow.triangle.swap", isWarning: false, caption: "地图已挪开", action: "primary", actionTitle: buttonTitle)
        }
        if isActive {
            return spot(.locating, placeName: placeName, statusText: "定位中", symbolName: "location.fill", isWarning: false, caption: "定位已写在这里", action: "primary", actionTitle: buttonTitle)
        }
        if failed {
            return spot(.failed, placeName: placeName, statusText: "未生效", symbolName: "exclamationmark.triangle.fill", isWarning: true, caption: "没有写成", action: "primary", actionTitle: buttonTitle)
        }
        return nil
    }

    static func shouldUpdate(_ previous: SpotActivitySnapshot?, to next: SpotActivitySnapshot) -> Bool {
        previous != next
    }

    private static func spot(
        _ status: SpotActivityStatus,
        placeName: String,
        statusText: String,
        symbolName: String,
        isWarning: Bool,
        caption: String,
        action: String,
        actionTitle: String
    ) -> SpotActivitySnapshot {
        SpotActivitySnapshot(
            status: status,
            placeName: placeName,
            statusText: statusText,
            symbolName: symbolName,
            isWarning: isWarning,
            showsRoute: false,
            caption: caption,
            action: action,
            actionTitle: actionTitle
        )
    }
}
