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
    var speedTenths: Int
    var routeName: String
    var progress: Double
    var remainingText: String
    var symbolName: String
    var isWarning: Bool
    var canToggle: Bool
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
        let remaining = RoutePlayback.formattedRemaining(
            meters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond
        )
        let speedTenths = Int((max(speedMetersPerSecond, 0.1) * 3.6 * 10).rounded())
        switch phase {
        case .inactive, .preparing:
            return nil
        case .playing:
            return RouteActivitySnapshot(
                phaseKey: .playing,
                statusText: RoutePlayback.formattedDuration(
                    meters: remainingMeters,
                    speedMetersPerSecond: speedMetersPerSecond
                ),
                remainingMinutes: minutes,
                speedTenths: speedTenths,
                routeName: routeName,
                progress: progress,
                remainingText: remaining,
                symbolName: symbolName,
                isWarning: false,
                canToggle: true
            )
        case .paused:
            let warning = statusMessage != userPauseMessage && !statusMessage.isEmpty
            return RouteActivitySnapshot(
                phaseKey: warning ? .warning : .paused,
                statusText: warning ? statusMessage : userPauseMessage,
                remainingMinutes: minutes,
                speedTenths: speedTenths,
                routeName: routeName,
                progress: progress,
                remainingText: remaining,
                symbolName: symbolName,
                isWarning: warning,
                canToggle: !warning
            )
        case .finished:
            return RouteActivitySnapshot(
                phaseKey: .finished,
                statusText: statusMessage,
                remainingMinutes: 0,
                speedTenths: speedTenths,
                routeName: routeName,
                progress: 1,
                remainingText: statusMessage,
                symbolName: symbolName,
                isWarning: false,
                canToggle: false
            )
        }
    }

    static func shouldUpdate(_ previous: RouteActivitySnapshot?, to next: RouteActivitySnapshot) -> Bool {
        guard let previous else { return true }
        return previous.phaseKey != next.phaseKey
            || previous.statusText != next.statusText
            || previous.remainingMinutes != next.remainingMinutes
            || previous.speedTenths != next.speedTenths
    }

    static func remainingMinutes(meters: Double, speedMetersPerSecond: Double) -> Int {
        let seconds = max(meters / max(speedMetersPerSecond, 0.1), 0)
        return max(1, Int((seconds / 60).rounded(.up)))
    }
}
