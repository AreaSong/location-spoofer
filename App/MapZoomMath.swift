import CoreLocation
import MapKit

enum MapZoomMath {
    private static let minimumDelta = 0.000_05
    private static let maximumLatitudeDelta = 170.0
    private static let maximumLongitudeDelta = 360.0

    static func scaledSpan(_ span: MKCoordinateSpan, factor: Double) -> MKCoordinateSpan {
        guard factor.isFinite, factor > 0 else { return span }
        return MKCoordinateSpan(
            latitudeDelta: min(max(span.latitudeDelta * factor, minimumDelta), maximumLatitudeDelta),
            longitudeDelta: min(max(span.longitudeDelta * factor, minimumDelta), maximumLongitudeDelta)
        )
    }

    static func viewportScaleLabel(distanceMeters: CLLocationDistance) -> String {
        let meters = max(0, distanceMeters)
        if meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        let kilometers = meters / 1_000
        if kilometers < 10 {
            return String(format: "%.1f km", kilometers)
        }
        return "\(Int(kilometers.rounded())) km"
    }
}
