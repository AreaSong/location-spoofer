import Foundation

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
        headingAvailable: Bool
    ) -> String? {
        guard stepCountingAvailable else { return stepCountingUnavailableMessage }
        if authorization == .denied { return permissionDeniedMessage }
        guard headingAvailable else { return headingUnavailableMessage }
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

enum PhysicalWalkStatusCopy {
    static func peek(
        isEnabled: Bool,
        spoofActive: Bool,
        isTracking: Bool,
        status: PhysicalWalkStatus,
        movedMeters: Double
    ) -> String? {
        guard isEnabled else { return nil }
        guard spoofActive else { return "真实走动已开，先开启虚拟定位" }
        guard isTracking else { return "真实走动已开" }
        switch status {
        case .waitingForHeading:
            return "等待朝向，请把手机朝前"
        case .tracking:
            let meters = Int(movedMeters.rounded())
            return meters > 0 ? "真实走动中 · \(meters)米" : "真实走动中，走起来才会移动"
        case .idle:
            return "真实走动已开"
        }
    }

    static func detail(
        isEnabled: Bool,
        spoofActive: Bool,
        status: PhysicalWalkStatus,
        movedMeters: Double,
        failureMessage: String
    ) -> String {
        if !failureMessage.isEmpty { return failureMessage }
        if !isEnabled {
            return "打开后，你走动时虚拟点会按相同方向移动。请把手机朝向行走方向。"
        }
        if !spoofActive {
            return "先开启虚拟定位，再走动。"
        }
        switch status {
        case .waitingForHeading:
            return "正在读取朝向，请把手机朝向行走方向。"
        case .tracking:
            let meters = Int(movedMeters.rounded())
            return meters > 0 ? "已移动 \(meters) 米" : "已开启，走起来虚拟点才会移动。"
        case .idle:
            return "已开启，走起来虚拟点才会移动。"
        }
    }

    static func chipSubtitle(isEnabled: Bool, isTracking: Bool) -> String? {
        guard isEnabled else { return nil }
        return isTracking ? "走动中" : "已开"
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
