import Foundation
import CoreLocation

enum RouteTravelMode: String, CaseIterable, Identifiable {
    case walk
    case bike

    var id: String { rawValue }

    var metersPerSecond: Double {
        switch self {
        case .walk: return 1.4
        case .bike: return 4.2
        }
    }

    var displayName: String {
        switch self {
        case .walk: return "步行"
        case .bike: return "骑行"
        }
    }
}

struct RouteTick: Equatable {
    let coordinatePair: CoordinatePair
    let progress: Double
    let remainingMeters: Double
    let isFinished: Bool
}

enum RoutePlayback {
    static let minimumDistanceMeters: Double = 10

    static func distanceMeters(from start: CoordinatePair, to end: CoordinatePair) -> Double {
        CoordinateConverter.distance(
            lat1: start.wgs84.latitude,
            lon1: start.wgs84.longitude,
            lat2: end.wgs84.latitude,
            lon2: end.wgs84.longitude
        )
    }

    static func interpolate(from start: CoordinatePair, to end: CoordinatePair, progress: Double) -> CoordinatePair {
        let clamped = min(1, max(0, progress))
        let latitude = start.wgs84.latitude + (end.wgs84.latitude - start.wgs84.latitude) * clamped
        let longitude = start.wgs84.longitude + (end.wgs84.longitude - start.wgs84.longitude) * clamped
        return CoordinateConverter.coordinatePair(
            lat: latitude,
            lon: longitude,
            mapCoordinateSystem: .wgs84
        )
    }

    static func tick(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode,
        elapsed: TimeInterval
    ) -> RouteTick {
        let distance = distanceMeters(from: start, to: end)
        let speed = max(mode.metersPerSecond, 0.1)
        let duration = max(distance / speed, 0.1)
        let progress = min(1, max(0, elapsed / duration))
        let pair = interpolate(from: start, to: end, progress: progress)
        let remaining = distance * (1 - progress)
        return RouteTick(
            coordinatePair: pair,
            progress: progress,
            remainingMeters: remaining,
            isFinished: progress >= 1
        )
    }

    static func formattedDistance(_ meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int(meters.rounded())) 米"
        }
        return String(format: "%.1f 公里", meters / 1_000)
    }

    static func formattedDuration(meters: Double, mode: RouteTravelMode) -> String {
        let seconds = max(meters / max(mode.metersPerSecond, 0.1), 0)
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 {
            return "约 1 分钟"
        }
        return "约 \(minutes) 分钟"
    }
}
