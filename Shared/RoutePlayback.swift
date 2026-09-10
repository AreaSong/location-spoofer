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

struct RoutePath: Equatable {
    let points: [CoordinatePair]
    let cumulativeMeters: [Double]

    var totalMeters: Double { cumulativeMeters.last ?? 0 }

    static func make(_ points: [CoordinatePair]) -> RoutePath {
        let cleaned = collapse(points)
        guard let first = cleaned.first else {
            return RoutePath(points: [], cumulativeMeters: [0])
        }
        guard cleaned.count > 1 else {
            return RoutePath(points: [first], cumulativeMeters: [0])
        }
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(cleaned.count)
        for index in 1..<cleaned.count {
            let meters = RoutePlayback.distanceMeters(from: cleaned[index - 1], to: cleaned[index])
            cumulative.append(cumulative[index - 1] + meters)
        }
        return RoutePath(points: cleaned, cumulativeMeters: cumulative)
    }

    private static func collapse(_ points: [CoordinatePair]) -> [CoordinatePair] {
        var result: [CoordinatePair] = []
        for point in points {
            if let last = result.last,
               abs(last.wgs84.latitude - point.wgs84.latitude) < 1e-8,
               abs(last.wgs84.longitude - point.wgs84.longitude) < 1e-8 {
                continue
            }
            result.append(point)
        }
        return result
    }
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

    static func interpolate(path: RoutePath, progress: Double) -> CoordinatePair {
        guard let first = path.points.first else {
            return CoordinateConverter.coordinatePair(lat: 0, lon: 0, mapCoordinateSystem: .wgs84)
        }
        guard path.points.count >= 2, path.totalMeters > 0 else { return first }
        let clamped = min(1, max(0, progress))
        let target = path.totalMeters * clamped
        if target >= path.totalMeters { return path.points.last ?? first }

        var index = 0
        while index + 1 < path.cumulativeMeters.count, path.cumulativeMeters[index + 1] < target {
            index += 1
        }
        let startMeters = path.cumulativeMeters[index]
        let endMeters = path.cumulativeMeters[index + 1]
        let span = max(endMeters - startMeters, 0.000_1)
        let local = (target - startMeters) / span
        return interpolate(from: path.points[index], to: path.points[index + 1], progress: local)
    }

    static func tick(path: RoutePath, mode: RouteTravelMode, elapsed: TimeInterval) -> RouteTick {
        let distance = path.totalMeters
        let speed = max(mode.metersPerSecond, 0.1)
        let duration = max(distance / speed, 0.1)
        let progress = min(1, max(0, elapsed / duration))
        return RouteTick(
            coordinatePair: interpolate(path: path, progress: progress),
            progress: progress,
            remainingMeters: distance * (1 - progress),
            isFinished: progress >= 1
        )
    }

    static func tick(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode,
        elapsed: TimeInterval
    ) -> RouteTick {
        tick(path: .make([start, end]), mode: mode, elapsed: elapsed)
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
