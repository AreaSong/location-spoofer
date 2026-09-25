import Foundation

enum RouteInterruption: String, Codable, Equatable {
    case playing
    case userPaused
    case pushFailed
    case activationFailed
}

struct RouteSession: Codable, Equatable {
    var routeID: UUID?
    var name: String
    var start: CoordinatePair
    var end: CoordinatePair
    var viaPoints: [CoordinatePair]
    var travelMode: RouteTravelMode
    var speedKilometersPerHour: Double
    var offsetMeters: Double
    var repeatMode: RouteRepeatMode
    var straightFallback: RoutePathFallback?
    var progress: Double
    var elapsed: TimeInterval
    var headingForward: Bool
    var interruption: RouteInterruption
    var updatedAt: Date

    static let lifetime: TimeInterval = 24 * 60 * 60

    func isRecoverable(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) <= Self.lifetime && now.timeIntervalSince(updatedAt) >= 0
    }

    func savedRoute() -> SavedRoute {
        SavedRoute(
            id: routeID ?? UUID(),
            name: name,
            start: start,
            end: end,
            travelMode: travelMode,
            speedKilometersPerHour: speedKilometersPerHour,
            offsetMeters: offsetMeters,
            repeatMode: repeatMode,
            viaPoints: viaPoints,
            pathPoints: nil,
            straightFallback: straightFallback,
            createdAt: updatedAt
        )
    }
}

final class RouteSessionStore {
    private enum Keys {
        static let session = "route_session_v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    func load(now: Date = Date()) -> RouteSession? {
        guard let data = defaults.data(forKey: Keys.session),
              let session = try? JSONDecoder().decode(RouteSession.self, from: data),
              session.isRecoverable(now: now) else {
            return nil
        }
        return session
    }

    func save(_ session: RouteSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: Keys.session)
    }

    func clear() {
        defaults.removeObject(forKey: Keys.session)
    }
}
