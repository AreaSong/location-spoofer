import Foundation
import CoreLocation

enum PhysicalWalkAuthorization: Equatable {
    case notDetermined
    case allowed
    case denied
}

enum PhysicalWalkSensorErrorAction: Equatable {
    case ignore
    case fail(String)
}

enum PhysicalWalkSensorPolicy {
    static let permissionDeniedMessage = "需要运动与健身权限才能真实走动。"
    static let sensorUnavailableMessage = "真实走动无法读取步伐，请稍后重试。"
    static let stepCountingUnavailableMessage = "这台设备不支持计步，无法使用真实走动。"
    static let headingUnavailableMessage = "这台设备没有罗盘，无法按朝向移动虚拟定位。"

    static func availabilityMessage(
        stepCountingAvailable: Bool,
        authorization: PhysicalWalkAuthorization,
        headingAvailable: Bool = true
    ) -> String? {
        guard stepCountingAvailable else { return stepCountingUnavailableMessage }
        if authorization == .denied { return permissionDeniedMessage }
        _ = headingAvailable
        return nil
    }

    static func action(
        forAuthorization authorization: PhysicalWalkAuthorization,
        isAuthorizationError: Bool
    ) -> PhysicalWalkSensorErrorAction {
        switch authorization {
        case .notDetermined:
            return .ignore
        case .denied:
            return .fail(permissionDeniedMessage)
        case .allowed:
            return isAuthorizationError ? .ignore : .fail(sensorUnavailableMessage)
        }
    }
}

struct PhysicalWalkSample: Equatable {
    var distanceMeters: Double?
    var steps: Int?
}

struct PhysicalWalkHeading: Equatable {
    var degrees: Double
    var accuracyDegrees: Double

    var isReliable: Bool {
        accuracyDegrees >= 0
    }
}

enum PhysicalWalkStatus: Equatable {
    case idle
    case waitingForHeading
    case tracking
}

enum PhysicalWalkApplyResult: Equatable {
    case unchanged
    case waitingForHeading
    case moved(deltaMeters: Double)
}

enum PhysicalWalkHeadingMode: Equatable {
    case followCompass
    case locked(degrees: Double)

    var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }
}

enum PhysicalWalkHeadingLock {
    static let cardinals: [(title: String, degrees: Double)] = [
        ("北", 0), ("东", 90), ("南", 180), ("西", 270)
    ]

    static func resolve(
        mode: PhysicalWalkHeadingMode,
        compass: PhysicalWalkHeading?
    ) -> PhysicalWalkHeading? {
        switch mode {
        case .followCompass:
            return compass
        case let .locked(degrees):
            return PhysicalWalkHeading(degrees: normalized(degrees), accuracyDegrees: 0)
        }
    }

    static func normalized(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    static func compassName(_ degrees: Double) -> String {
        let value = normalized(degrees)
        switch value {
        case 0..<22.5, 337.5...360: return "北"
        case 22.5..<67.5: return "东北"
        case 67.5..<112.5: return "东"
        case 112.5..<157.5: return "东南"
        case 157.5..<202.5: return "南"
        case 202.5..<247.5: return "西南"
        case 247.5..<292.5: return "西"
        default: return "西北"
        }
    }

    static func pickerSummary(headingDegrees: Double?, locked: Bool) -> String {
        if locked {
            guard let headingDegrees else { return "未定" }
            return labeledDegrees(headingDegrees)
        }
        guard let headingDegrees else { return "罗盘" }
        return "罗盘 \(Int(normalized(headingDegrees).rounded()))°"
    }

    static func labeledDegrees(_ degrees: Double) -> String {
        let value = normalized(degrees)
        return "\(compassName(value)) \(Int(value.rounded()))°"
    }
}

/// 朝向点选主要在开走前用一次：还没有方向时展开，已有方向则收起。
enum PhysicalWalkHeadingPicker {
    static func shouldRevealControls(
        isEnabled: Bool,
        status _: PhysicalWalkStatus,
        hasResolvedHeading: Bool,
        followsCompass: Bool = false
    ) -> Bool {
        _ = followsCompass
        guard isEnabled else { return false }
        return !hasResolvedHeading
    }
}

enum PhysicalWalkStatusCopy {
    static func peek(
        isEnabled: Bool,
        spoofActive: Bool,
        isTracking: Bool,
        status: PhysicalWalkStatus,
        movedMeters: Double,
        headingDegrees: Double? = nil
    ) -> String? {
        guard isEnabled else { return nil }
        guard spoofActive else { return "真实走动已开，先开启虚拟定位" }
        guard isTracking else { return "真实走动已开" }
        switch status {
        case .waitingForHeading:
            return "点东南西北锁定方向，或把手机朝前"
        case .tracking:
            let meters = Int(movedMeters.rounded())
            let prefix = meters > 0 ? "真实走动中 · \(meters)米" : "真实走动中，走起来才会移动"
            return appendedHeading(prefix, headingDegrees)
        case .idle:
            return appendedHeading("真实走动已开", headingDegrees)
        }
    }

    static func detail(
        isEnabled: Bool,
        spoofActive: Bool,
        status: PhysicalWalkStatus,
        movedMeters: Double,
        failureMessage: String,
        headingDegrees: Double? = nil,
        headingLocked: Bool = false
    ) -> String {
        if !failureMessage.isEmpty { return failureMessage }
        if !isEnabled {
            return "打开后，你走动时虚拟点沿箭头方向移动。地图北朝上，可点东南西北锁定方向。"
        }
        if !spoofActive {
            return "先开启虚拟定位，再走动。"
        }
        let headingNote = headingNote(degrees: headingDegrees, locked: headingLocked)
        switch status {
        case .waitingForHeading:
            return "还没有朝向。点北/东/南/西锁定地图方向，或把手机朝前跟随罗盘。"
        case .tracking:
            let meters = Int(movedMeters.rounded())
            let movement = meters > 0 ? "已移动 \(meters) 米" : "已开启，走起来虚拟点才会移动"
            return headingNote.map { "\(movement)，\($0)。" } ?? "\(movement)。"
        case .idle:
            return headingNote.map { "已开启，\($0)。走起来虚拟点才会移动。" }
                ?? "已开启，走起来虚拟点才会移动。"
        }
    }

    static func chipSubtitle(isEnabled: Bool, isTracking: Bool) -> String? {
        guard isEnabled else { return nil }
        return isTracking ? "走动中" : "已开"
    }

    private static func appendedHeading(_ prefix: String, _ headingDegrees: Double?) -> String {
        guard let headingDegrees else { return prefix }
        return "\(prefix) · \(PhysicalWalkHeadingLock.compassName(headingDegrees))"
    }

    private static func headingNote(degrees: Double?, locked: Bool) -> String? {
        guard let degrees else { return nil }
        let name = PhysicalWalkHeadingLock.compassName(degrees)
        return locked ? "朝向\(name)（已锁定）" : "朝向\(name)（跟随罗盘）"
    }
}

enum PhysicalWalkDisplacement {
    static let earthRadiusMeters = LocationCoordinateOffset.earthRadiusMeters
    static let defaultStrideMeters = 0.74
    static let minimumDeltaMeters = 0.05

    /// Compass heading: 0 is north, 90 is east, clockwise.
    static func offsetWGS84(
        latitude: Double,
        longitude: Double,
        distanceMeters: Double,
        headingDegrees: Double
    ) -> (latitude: Double, longitude: Double) {
        LocationCoordinateOffset.offsetWGS84(
            latitude: latitude,
            longitude: longitude,
            radiusMeters: max(0, distanceMeters),
            angleRadians: headingDegrees * .pi / 180,
            radiusFraction: 1
        )
    }
}

enum PhysicalWalkSession {
    static func shouldTrack(
        isEnabled: Bool,
        spoofActive: Bool,
        routePlaying: Bool,
        routeWaiting: Bool,
        preview: Bool,
        useBlocked: Bool
    ) -> Bool {
        isEnabled && spoofActive && !routePlaying && !routeWaiting && !preview && !useBlocked
    }

    static func shouldPauseRoute(isEnabled: Bool, routePlaying: Bool) -> Bool {
        isEnabled && routePlaying
    }

    static func shouldDisableForRoutePlayback(routePlaying: Bool, routeWaiting: Bool) -> Bool {
        routePlaying || routeWaiting
    }
}

enum WalkPuckMapPlacement {
    static func coordinate(
        walkEnabled: Bool,
        spoofActive: Bool,
        writtenLatitude: Double?,
        writtenLongitude: Double?,
        mapSystem: CoordinateConverter.MapCoordinateSystem
    ) -> CLLocationCoordinate2D? {
        guard walkEnabled, spoofActive else { return nil }
        guard let latitude = writtenLatitude, let longitude = writtenLongitude else {
            return nil
        }
        return CoordinatePair(
            mapCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            mapCoordinateSystem: .wgs84
        ).coordinate(for: mapSystem)
    }
}

struct PhysicalWalkEngine: Equatable {
    var latitude: Double
    var longitude: Double
    var movedMeters = 0.0
    var pendingMeters = 0.0
    private var lastDistanceMeters: Double?
    private var lastSteps: Int?

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    mutating func apply(
        sample: PhysicalWalkSample,
        heading: PhysicalWalkHeading?
    ) -> PhysicalWalkApplyResult {
        let delta = Self.deltaMeters(
            sample: sample,
            lastDistance: lastDistanceMeters,
            lastSteps: lastSteps
        )
        remember(sample)
        if delta >= PhysicalWalkDisplacement.minimumDeltaMeters {
            pendingMeters += delta
        }
        guard pendingMeters >= PhysicalWalkDisplacement.minimumDeltaMeters else {
            return .unchanged
        }
        guard let heading, heading.isReliable else {
            return .waitingForHeading
        }
        let applied = pendingMeters
        let next = PhysicalWalkDisplacement.offsetWGS84(
            latitude: latitude,
            longitude: longitude,
            distanceMeters: applied,
            headingDegrees: heading.degrees
        )
        latitude = next.latitude
        longitude = next.longitude
        movedMeters += applied
        pendingMeters = 0
        return .moved(deltaMeters: applied)
    }

    private mutating func remember(_ sample: PhysicalWalkSample) {
        if let distance = sample.distanceMeters {
            lastDistanceMeters = distance
        }
        if let steps = sample.steps {
            lastSteps = steps
        }
    }

    private static func deltaMeters(
        sample: PhysicalWalkSample,
        lastDistance: Double?,
        lastSteps: Int?
    ) -> Double {
        if let current = sample.distanceMeters {
            guard let lastDistance else { return 0 }
            return max(0, current - lastDistance)
        }
        guard let steps = sample.steps else { return 0 }
        guard let lastSteps else { return 0 }
        return Double(max(0, steps - lastSteps)) * PhysicalWalkDisplacement.defaultStrideMeters
    }
}
