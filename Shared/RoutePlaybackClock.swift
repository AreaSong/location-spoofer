import CoreLocation
import Foundation

/// 播放进度、当前位置和状态文案每秒都会变。
/// 它们单独发布，避免首页因为进度 tick 整页重绘。
@MainActor
final class RoutePlaybackClock: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: CoordinatePair?
    @Published private(set) var statusMessage = ""
    @Published private(set) var markerCoordinate: CLLocationCoordinate2D?
    @Published private(set) var headingDegrees: Double?

    func setProgress(_ value: Double) {
        guard progress != value else { return }
        progress = value
    }

    func setCurrent(_ value: CoordinatePair?) {
        guard current != value else { return }
        current = value
    }

    func setStatusMessage(_ value: String) {
        guard statusMessage != value else { return }
        statusMessage = value
    }

    func setMarker(_ coordinate: CLLocationCoordinate2D?) {
        guard !sameCoordinate(markerCoordinate, coordinate) else { return }
        markerCoordinate = coordinate
    }

    func setHeading(_ value: Double?) {
        guard !sameHeading(headingDegrees, value) else { return }
        headingDegrees = value
    }

    private func sameCoordinate(
        _ lhs: CLLocationCoordinate2D?,
        _ rhs: CLLocationCoordinate2D?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.latitude == right.latitude && left.longitude == right.longitude
        default:
            return false
        }
    }

    private func sameHeading(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            var diff = abs(left - right).truncatingRemainder(dividingBy: 360)
            if diff > 180 { diff = 360 - diff }
            return diff < 0.5
        default:
            return false
        }
    }
}
