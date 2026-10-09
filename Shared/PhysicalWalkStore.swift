import Combine
import Foundation

@MainActor
final class PhysicalWalkStore: ObservableObject {
    static let shared = PhysicalWalkStore()

    private enum Key {
        static let enabled = "physicalWalk.enabled"
        static let customHeadingEnabled = "physicalWalk.customHeading.enabled"
        static let initialHeadingDegrees = "physicalWalk.customHeading.initialDegrees"
        static let strideMeters = "physicalWalk.strideMeters"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isCustomHeadingEnabled: Bool
    @Published private(set) var initialHeadingDegrees: Double
    @Published private(set) var strideMeters: Double
    @Published private(set) var lastFailureMessage = ""
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        isCustomHeadingEnabled = defaults.bool(forKey: Key.customHeadingEnabled)
        initialHeadingDegrees = PhysicalWalkHeadingLock.normalized(
            defaults.double(forKey: Key.initialHeadingDegrees)
        )
        if defaults.object(forKey: Key.strideMeters) == nil {
            strideMeters = PhysicalWalkDisplacement.defaultStrideMeters
        } else {
            strideMeters = PhysicalWalkDisplacement.clampedStride(
                defaults.double(forKey: Key.strideMeters)
            )
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled {
            lastFailureMessage = ""
        }
    }

    func setCustomHeadingEnabled(_ enabled: Bool) {
        isCustomHeadingEnabled = enabled
        defaults.set(enabled, forKey: Key.customHeadingEnabled)
    }

    func setInitialHeadingDegrees(_ degrees: Double) {
        let value = PhysicalWalkHeadingLock.normalized(degrees)
        guard initialHeadingDegrees != value else { return }
        initialHeadingDegrees = value
        defaults.set(value, forKey: Key.initialHeadingDegrees)
    }

    func setStrideMeters(_ meters: Double) {
        let value = PhysicalWalkDisplacement.clampedStride(meters)
        guard strideMeters != value else { return }
        strideMeters = value
        defaults.set(value, forKey: Key.strideMeters)
    }

    func noteFailure(_ message: String) {
        lastFailureMessage = message
        setEnabled(false)
    }

    func clearFailure() {
        lastFailureMessage = ""
    }
}
