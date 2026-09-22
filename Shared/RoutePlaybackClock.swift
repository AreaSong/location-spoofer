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
}
