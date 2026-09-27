import Combine
import Foundation

@MainActor
final class PhysicalWalkStore: ObservableObject {
    static let shared = PhysicalWalkStore()

    private enum Key {
        static let enabled = "physicalWalk.enabled"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastFailureMessage = ""
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled {
            lastFailureMessage = ""
        }
    }

    func noteFailure(_ message: String) {
        lastFailureMessage = message
        setEnabled(false)
    }

    func clearFailure() {
        lastFailureMessage = ""
    }
}
