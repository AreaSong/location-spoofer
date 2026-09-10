import Foundation

extension RoutePlaybackController {
    func readyStatusMessage(meters: Double) -> String {
        var prefix = RoutePlayback.formattedDistance(meters)
        if !vias.isEmpty {
            prefix += " · \(vias.count) 个途经"
        }
        let durationText = RoutePlayback.formattedDuration(
            meters: meters,
            speedMetersPerSecond: speedMetersPerSecond
        )
        switch repeatMode {
        case .once:
            let hint = vias.isEmpty ? "" : "。点橙色数字可删除途经"
            return "\(prefix)，\(durationText)\(hint)"
        case .roundTrip:
            let roundMeters = meters * 2
            return "往返 \(RoutePlayback.formattedDistance(roundMeters))，\(RoutePlayback.formattedDuration(meters: roundMeters, speedMetersPerSecond: speedMetersPerSecond))"
        case .loop:
            return "\(prefix)，循环走，直到暂停"
        }
    }

    func playbackStatusMessage() -> String {
        let remaining = RoutePlayback.formattedRemaining(
            meters: remainingMeters,
            speedMetersPerSecond: speedMetersPerSecond
        )
        if !headingForward {
            return "走回起点 · \(remaining)"
        }
        if repeatMode == .loop {
            return "循环中 · \(remaining)"
        }
        if repeatMode == .roundTrip {
            return "走向终点 · \(remaining)"
        }
        return "正在从起点沿路走到终点。\(remaining)"
    }

    func finishedStatusMessage() -> String {
        if headingForward {
            return "已走到终点。你的虚拟定位现在停在这里。"
        }
        return "已走回起点。你的虚拟定位现在停在这里。"
    }
}
