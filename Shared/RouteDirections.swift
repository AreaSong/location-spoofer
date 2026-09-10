import Foundation
import MapKit

enum RouteDirections {
    @MainActor
    static func waypoints(
        along anchors: [CoordinatePair],
        mode: RouteTravelMode
    ) async -> [CoordinatePair] {
        guard anchors.count >= 2 else { return anchors }
        var combined: [CoordinatePair] = []
        for index in 0..<(anchors.count - 1) {
            let leg = await waypoints(from: anchors[index], to: anchors[index + 1], mode: mode)
            if combined.isEmpty {
                combined = leg
            } else if leg.count > 1 {
                combined.append(contentsOf: leg.dropFirst())
            }
        }
        return combined
    }

    @MainActor
    static func waypoints(
        from start: CoordinatePair,
        to end: CoordinatePair,
        mode: RouteTravelMode
    ) async -> [CoordinatePair] {
        let system = CoordinateConverter.currentMapCoordinateSystem
        let source = start.coordinate(for: system)
        let destination = end.coordinate(for: system)
        let types: [MKDirectionsTransportType] = mode == .walk
            ? [.walking, .automobile]
            : [.automobile, .walking]
        for transportType in types {
            if let points = await routePoints(
                from: source,
                to: destination,
                transportType: transportType,
                mapCoordinateSystem: system
            ), RoutePath.make(points).totalMeters >= RoutePlayback.minimumDistanceMeters {
                return points
            }
        }
        return [start, end]
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
