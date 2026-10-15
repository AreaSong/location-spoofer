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
    /// 首页被 sheet 盖住时不把进度发到 SwiftUI，播放和写入照常进行。
    private var publishesUI = true
    private var pendingProgress: Double?
    private var pendingCurrent: CoordinatePair?
    private var pendingStatusMessage: String?
    private var pendingMarker: CLLocationCoordinate2D?
    private var pendingHeading: Double?
    private var hasPendingCurrent = false
    private var hasPendingMarker = false
    private var hasPendingHeading = false

    func setPublishesUI(_ enabled: Bool) {
        guard publishesUI != enabled else { return }
        publishesUI = enabled
        guard enabled else { return }
        if let value = pendingProgress {
            pendingProgress = nil
            setProgress(value)
        }
        if hasPendingCurrent {
            hasPendingCurrent = false
            let value = pendingCurrent
            pendingCurrent = nil
            setCurrent(value)
        }
        if let value = pendingStatusMessage {
            pendingStatusMessage = nil
            setStatusMessage(value)
        }
        if hasPendingMarker {
            hasPendingMarker = false
            let value = pendingMarker
            pendingMarker = nil
            setMarker(value)
        }
        if hasPendingHeading {
            hasPendingHeading = false
            let value = pendingHeading
            pendingHeading = nil
            setHeading(value)
        }
    }

    func setProgress(_ value: Double) {
        guard progress != value else { return }
        guard publishesUI else {
            pendingProgress = value
            return
        }
        progress = value
    }

    func setCurrent(_ value: CoordinatePair?) {
        guard current != value else { return }
        guard publishesUI else {
            pendingCurrent = value
            hasPendingCurrent = true
            return
        }
        current = value
    }

    func setStatusMessage(_ value: String) {
        guard statusMessage != value else { return }
        guard publishesUI else {
            pendingStatusMessage = value
            return
        }
        statusMessage = value
    }

    func setMarker(_ coordinate: CLLocationCoordinate2D?) {
        guard !sameCoordinate(markerCoordinate, coordinate) else { return }
        guard publishesUI else {
            pendingMarker = coordinate
            hasPendingMarker = true
            return
        }
        markerCoordinate = coordinate
    }

    func setHeading(_ value: Double?) {
        guard !sameHeading(headingDegrees, value) else { return }
        guard publishesUI else {
            pendingHeading = value
            hasPendingHeading = true
            return
        }
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
