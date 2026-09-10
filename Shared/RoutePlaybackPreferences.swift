import Foundation

struct RoutePlaybackPreferences: Equatable, Codable {
    var travelMode: RouteTravelMode
    var speedKilometersPerHour: Double
    var offsetMeters: Double
    var repeatMode: RouteRepeatMode

    static let `default` = RoutePlaybackPreferences(
        travelMode: .walk,
        speedKilometersPerHour: RouteTravelMode.walk.kilometersPerHour,
        offsetMeters: 0,
        repeatMode: .once
    )
}

struct RoutePlaybackPreferenceStore {
    private enum Keys {
        static let prefs = "route_playback_preferences_v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    func load() -> RoutePlaybackPreferences {
        guard let data = defaults.data(forKey: Keys.prefs),
              let decoded = try? JSONDecoder().decode(RoutePlaybackPreferences.self, from: data) else {
            return .default
        }
        return RoutePlaybackPreferences(
            travelMode: decoded.travelMode,
            speedKilometersPerHour: min(40, max(1, decoded.speedKilometersPerHour)),
            offsetMeters: min(80, max(0, decoded.offsetMeters)),
            repeatMode: decoded.repeatMode
        )
    }

    func save(_ prefs: RoutePlaybackPreferences) {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: Keys.prefs)
    }
}
