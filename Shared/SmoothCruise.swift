import CoreLocation
import Foundation

enum SmoothCruisePolicy {
    static let durationSeconds = 1.4
    static let minimumDistanceMeters: CLLocationDistance = 50
    static let maximumDistanceMeters: CLLocationDistance = 500_000

    static var durationSecondsText: String {
        String(format: "%.1f", durationSeconds)
    }

    static func shouldInterpolate(
        enabled: Bool,
        spoofActive: Bool,
        isRouteActivation: Bool,
        from: CLLocationCoordinate2D?,
        to: CLLocationCoordinate2D
    ) -> Bool {
        guard enabled, spoofActive, !isRouteActivation, let from else {
            return false
        }
        let origin = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let destination = CLLocation(latitude: to.latitude, longitude: to.longitude)
        let distance = origin.distance(from: destination)
        return distance >= minimumDistanceMeters && distance <= maximumDistanceMeters
    }
}
