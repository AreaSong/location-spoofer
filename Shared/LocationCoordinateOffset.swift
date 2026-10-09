import Foundation

/// Offsets a WGS-84 point once per apply, using a uniform disk of the given radius.
enum LocationCoordinateOffset {
    static let earthRadiusMeters = 6_371_000.0

    static func offsetWGS84(
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        angleRadians: Double? = nil,
        radiusFraction: Double? = nil
    ) -> (latitude: Double, longitude: Double) {
        let radius = max(0, radiusMeters)
        guard radius > 0 else {
            return (latitude, longitude)
        }

        let angle = angleRadians ?? Double.random(in: 0..<(2 * .pi))
        let fraction = min(1, max(0, radiusFraction ?? sqrt(Double.random(in: 0...1))))
        let distance = radius * fraction
        let latitudeRadians = latitude * .pi / 180
        let parallelRadius = earthRadiusMeters * max(1e-12, abs(cos(latitudeRadians)))
        let latitudeDelta = (distance * cos(angle) / earthRadiusMeters) * 180 / .pi
        let longitudeDelta = (distance * sin(angle) / parallelRadius) * 180 / .pi
        return (latitude + latitudeDelta, longitude + longitudeDelta)
    }
}

@MainActor
final class RandomRadiusStore: ObservableObject {
    static let shared = RandomRadiusStore()
    static let minimumMeters = 10.0
    static let maximumMeters = 200.0
    static let defaultMeters = 50.0

    private enum Key {
        static let isEnabled = "randomRadius.isEnabled"
        static let radius = "randomRadius.radius"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var radius: Double
    private let defaults: UserDefaults

    var effectiveRadiusMeters: Double {
        isEnabled ? radius : 0
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        radius = Self.clamped(defaults.object(forKey: Key.radius) as? Double ?? Self.defaultMeters)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.isEnabled)
    }

    func setRadius(_ radius: Double) {
        let value = Self.clamped(radius)
        self.radius = value
        defaults.set(value, forKey: Key.radius)
    }

    static func clamped(_ radius: Double) -> Double {
        min(maximumMeters, max(minimumMeters, radius))
    }
}
