import Foundation

enum AppGroup {
    static let identifier = "group.com.paopaolabs.location-spoofer"
    static let defaults = UserDefaults(suiteName: identifier) ?? .standard

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var isSharedContainerAvailable: Bool { sharedContainerURL != nil }

    static var containerURL: URL {
        if let url = sharedContainerURL { return url }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocationSpoofer", isDirectory: true)
    }
}

enum WlocKeys {
    static let coords = "wloc_settings"
}

struct WlocSettings: Codable {
    var longitude: Double
    var latitude: Double
    var accuracy: Int
    var enabled: Bool
}

enum WlocSettingsStore {
    static func load() -> WlocSettings? {
        guard let data = AppGroup.defaults.data(forKey: WlocKeys.coords) else { return nil }
        return try? JSONDecoder().decode(WlocSettings.self, from: data)
    }

    static func save(_ settings: WlocSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppGroup.defaults.set(data, forKey: WlocKeys.coords)
    }

    static func clear() {
        save(WlocSettings(longitude: 0, latitude: 0, accuracy: 25, enabled: false))
    }
}

@MainActor
final class MotionSimulationStore: ObservableObject {
    static let shared = MotionSimulationStore()

    private enum Key {
        static let enabled = "motionSimulation.enabled"
    }

    @Published private(set) var isEnabled: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
    }
}

@MainActor
final class RandomRadiusStore: ObservableObject {
    static let shared = RandomRadiusStore()
    static let minimumMeters = 10.0
    static let maximumMeters = 200.0
    static let defaultMeters = 50.0

    private enum Key {
        static let isEnabled = "randomRadius.isEnabled"
        static let radius = "randomRadius.radius"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var radius: Double
    private let defaults: UserDefaults

    var effectiveRadiusMeters: Double {
        isEnabled ? radius : 0
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        radius = Self.clamped(defaults.object(forKey: Key.radius) as? Double ?? Self.defaultMeters)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.isEnabled)
    }

    func setRadius(_ radius: Double) {
        let value = Self.clamped(radius)
        self.radius = value
        defaults.set(value, forKey: Key.radius)
    }

    static func clamped(_ radius: Double) -> Double {
        min(maximumMeters, max(minimumMeters, radius))
    }
}

@MainActor
final class LocationAccuracyStore: ObservableObject {
    static let shared = LocationAccuracyStore()
    static let minimumMeters = 5
    static let maximumMeters = 100
    static let defaultMeters = 25

    private enum Key {
        static let meters = "locationAccuracy.meters"
    }

    @Published private(set) var meters: Int
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if defaults.object(forKey: Key.meters) == nil {
            meters = Self.defaultMeters
        } else {
            meters = Self.clamped(defaults.integer(forKey: Key.meters))
        }
    }

    func setMeters(_ meters: Int) {
        let value = Self.clamped(meters)
        self.meters = value
        defaults.set(value, forKey: Key.meters)
    }

    static func clamped(_ meters: Int) -> Int {
        min(maximumMeters, max(minimumMeters, meters))
    }
}

@MainActor
final class CoordinateInputPreferenceStore: ObservableObject {
    static let shared = CoordinateInputPreferenceStore()

    private enum Key {
        static let lastSystem = "coordinateInput.lastSystem"
    }

    @Published private(set) var lastSystem: CoordinateConverter.MapCoordinateSystem
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Key.lastSystem),
           let stored = CoordinateConverter.MapCoordinateSystem(rawValue: raw) {
            lastSystem = stored
        } else {
            lastSystem = .gcj02
        }
    }

    func setLastSystem(_ system: CoordinateConverter.MapCoordinateSystem) {
        lastSystem = system
        defaults.set(system.rawValue, forKey: Key.lastSystem)
    }
}

@MainActor
final class ThirdPartyModuleSourceStore: ObservableObject {
    static let shared = ThirdPartyModuleSourceStore()

    private enum Key {
        static let useMirror = "thirdPartyModule.useMirror"
        static let distribution = "thirdPartyModule.distribution"
    }

    @Published private(set) var distribution: ThirdPartyModuleDistribution
    private let defaults: UserDefaults

    var useMirror: Bool { distribution == .remoteMirror }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Key.distribution),
           let stored = ThirdPartyModuleDistribution(rawValue: raw) {
            distribution = stored
        } else {
            distribution = .onDevice
        }
    }

    func setDistribution(_ distribution: ThirdPartyModuleDistribution) {
        self.distribution = distribution
        defaults.set(distribution.rawValue, forKey: Key.distribution)
        defaults.removeObject(forKey: Key.useMirror)
    }

    func setUseMirror(_ enabled: Bool) {
        setDistribution(enabled ? .remoteMirror : .remoteDirect)
    }
}

enum VirtualLocationTipKind: Equatable {
    case activation
    case deactivation
}

/// Owns the persistent counters and suppression flags for automatic operation tips.
/// Manual help sheets do not consult or mutate this store.
struct VirtualLocationTipPreferences {
    static let minimumCountForSuppression = 3

    private enum Key {
        static let activationCount = "virtualLocationTip.activationCount"
        static let deactivationCount = "virtualLocationTip.deactivationCount"
        static let activationSuppressed = "virtualLocationTip.activationSuppressed"
        static let deactivationSuppressed = "virtualLocationTip.deactivationSuppressed"
        static let legacyActivationSuppressed = "activationTipDisabled"
    }

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults

    init(
        defaults: UserDefaults = AppGroup.defaults,
        legacyDefaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
    }

    @discardableResult
    func recordSuccessfulOperation(_ kind: VirtualLocationTipKind) -> Int {
        let key = countKey(for: kind)
        let next = defaults.integer(forKey: key) + 1
        defaults.set(next, forKey: key)
        return next
    }

    func shouldPresentAutomaticTip(_ kind: VirtualLocationTipKind) -> Bool {
        !isSuppressed(kind)
    }

    func canSuppress(_ kind: VirtualLocationTipKind) -> Bool {
        defaults.integer(forKey: countKey(for: kind)) >= Self.minimumCountForSuppression
    }

    func suppress(_ kind: VirtualLocationTipKind) {
        guard canSuppress(kind) else { return }
        defaults.set(true, forKey: suppressionKey(for: kind))
    }

    private func isSuppressed(_ kind: VirtualLocationTipKind) -> Bool {
        if kind == .activation,
           legacyDefaults.bool(forKey: Key.legacyActivationSuppressed) {
            return true
        }
        return defaults.bool(forKey: suppressionKey(for: kind))
    }

    private func countKey(for kind: VirtualLocationTipKind) -> String {
        switch kind {
        case .activation: return Key.activationCount
        case .deactivation: return Key.deactivationCount
        }
    }

    private func suppressionKey(for kind: VirtualLocationTipKind) -> String {
        switch kind {
        case .activation: return Key.activationSuppressed
        case .deactivation: return Key.deactivationSuppressed
        }
    }
}

/// Controls the optional prompt asking users to share a verified third-party setup.
struct ThirdPartyCommunityPromptPreferences {
    static let minimumCountForSuppression = 3

    private enum Key {
        static let presentationCount = "thirdPartyCommunityPrompt.presentationCount"
        static let suppressed = "thirdPartyCommunityPrompt.suppressed"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    @discardableResult
    func recordPresentation() -> Int {
        let next = defaults.integer(forKey: Key.presentationCount) + 1
        defaults.set(next, forKey: Key.presentationCount)
        return next
    }

    func shouldPresent() -> Bool {
        !defaults.bool(forKey: Key.suppressed)
    }

    func canSuppress() -> Bool {
        defaults.integer(forKey: Key.presentationCount) >= Self.minimumCountForSuppression
    }

    func suppress() {
        guard canSuppress() else { return }
        defaults.set(true, forKey: Key.suppressed)
    }
}
