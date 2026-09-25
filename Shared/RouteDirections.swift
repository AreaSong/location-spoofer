import Foundation
import MapKit

enum RoutePathFallback: String, Codable, Equatable {
    case all
    case partial

    var notice: String {
        switch self {
        case .all:
            return "沿路规划失败，已改用直线"
        case .partial:
            return "部分路段规划失败，已改用直线"
        }
    }

    static func from(straightLegCount: Int, legCount: Int) -> RoutePathFallback? {
        guard straightLegCount > 0, legCount > 0 else { return nil }
        return straightLegCount >= legCount ? .all : .partial
    }
}

struct RoutePlan: Equatable {
    var points: [CoordinatePair]
    var straightLegCount: Int
    var legCount: Int

    var fallback: RoutePathFallback? {
        RoutePathFallback.from(straightLegCount: straightLegCount, legCount: legCount)
    }
}

protocol RouteDirectionsProviding {
    @MainActor
    func routePoints(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode
    ) async -> [CoordinatePair]?
}

struct MapKitRouteDirections: RouteDirectionsProviding {
    @MainActor
    func routePoints(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode
    ) async -> [CoordinatePair]? {
        let system = CoordinateConverter.currentMapCoordinateSystem
        let source = start.coordinate(for: system)
        let destination = end.coordinate(for: system)
        let types: [MKDirectionsTransportType] = mode == .walk
            ? [.walking, .automobile]
            : [.automobile, .walking]
        for transportType in types {
            if let points = await Self.routePoints(
                from: source,
                to: destination,
                transportType: transportType,
                mapCoordinateSystem: system
            ), RoutePath.make(points).totalMeters >= RoutePlayback.minimumDistanceMeters {
                return points
            }
        }
        return nil
    }

    private static func routePoints(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType,
        mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem
    ) async -> [CoordinatePair]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        request.requestsAlternateRoutes = false
        do {
            let response = try await calculate(request)
            guard let polyline = response.routes.first?.polyline else { return nil }
            return coordinates(of: polyline).map { coordinate in
                CoordinatePair(mapCoordinate: coordinate, mapCoordinateSystem: mapCoordinateSystem)
            }
        } catch {
            RuntimeLogger.warning("APP", "路线", "沿路规划失败，改用直线", details: [
                "交通方式": transportType == .walking ? "步行" : "驾车",
                "原因": error.localizedDescription
            ])
            return nil
        }
    }

    private static func calculate(_ request: MKDirections.Request) async throws -> MKDirections.Response {
        try await withCheckedThrowingContinuation { continuation in
            MKDirections(request: request).calculate { response, error in
                if let response {
                    continuation.resume(returning: response)
                } else {
                    continuation.resume(throwing: error ?? URLError(.cannotParseResponse))
                }
            }
        }
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var points = Array(
            repeating: kCLLocationCoordinate2DInvalid,
            count: polyline.pointCount
        )
        polyline.getCoordinates(&points, range: NSRange(location: 0, length: polyline.pointCount))
        return points.filter { CLLocationCoordinate2DIsValid($0) }
    }
}

enum RouteDirections {
    @MainActor
    static var provider: any RouteDirectionsProviding = MapKitRouteDirections()

    @MainActor
    static func waypoints(
        along anchors: [CoordinatePair],
        mode: RouteTravelMode,
        provider: (any RouteDirectionsProviding)? = nil
    ) async -> RoutePlan {
        guard anchors.count >= 2 else {
            return RoutePlan(points: anchors, straightLegCount: 0, legCount: 0)
        }
        let directions = provider ?? Self.provider
        var combined: [CoordinatePair] = []
        var straightLegCount = 0
        let legCount = anchors.count - 1
        for index in 0..<legCount {
            let leg = await waypoints(
                from: anchors[index],
                to: anchors[index + 1],
                mode: mode,
                provider: directions
            )
            straightLegCount += leg.straightLegCount
            if combined.isEmpty {
                combined = leg.points
            } else if leg.points.count > 1 {
                combined.append(contentsOf: leg.points.dropFirst())
            }
        }
        return RoutePlan(points: combined, straightLegCount: straightLegCount, legCount: legCount)
    }

    @MainActor
    static func waypoints(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode,
        provider: (any RouteDirectionsProviding)? = nil
    ) async -> RoutePlan {
        let directions = provider ?? Self.provider
        if let points = await directions.routePoints(from: start, to: end, mode: mode),
           RoutePath.make(points).totalMeters >= RoutePlayback.minimumDistanceMeters {
            return RoutePlan(points: points, straightLegCount: 0, legCount: 1)
        }
        return RoutePlan(points: [start, end], straightLegCount: 1, legCount: 1)
    }
}
