import Foundation

struct PhysicalWalkSample: Equatable {
    var distanceMeters: Double?
    var steps: Int?
}

struct PhysicalWalkHeading: Equatable {
    var degrees: Double
    var accuracyDegrees: Double

    var isReliable: Bool {
        accuracyDegrees >= 0
            && accuracyDegrees <= PhysicalWalkDisplacement.maximumHeadingAccuracyDegrees
    }
}

enum PhysicalWalkApplyResult: Equatable {
    case unchanged
    case waitingForHeading
    case moved(deltaMeters: Double)
}

enum PhysicalWalkDisplacement {
    static let earthRadiusMeters = LocationCoordinateOffset.earthRadiusMeters
    static let defaultStrideMeters = 0.74
    static let minimumDeltaMeters = 0.05
    static let maximumHeadingAccuracyDegrees = 25.0

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
        guard delta >= PhysicalWalkDisplacement.minimumDeltaMeters else {
            return .unchanged
        }
        guard let heading, heading.isReliable else {
            return .waitingForHeading
        }
        let next = PhysicalWalkDisplacement.offsetWGS84(
            latitude: latitude,
            longitude: longitude,
            distanceMeters: delta,
            headingDegrees: heading.degrees
        )
        latitude = next.latitude
        longitude = next.longitude
        movedMeters += delta
        return .moved(deltaMeters: delta)
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
