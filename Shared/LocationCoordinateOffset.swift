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
