import Combine
import Foundation

struct SavedRoute: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var start: CoordinatePair
    var end: CoordinatePair
    var travelMode: RouteTravelMode
    var speedKilometersPerHour: Double
    var offsetMeters: Double
    var repeatMode: RouteRepeatMode
    var viaPoints: [CoordinatePair]
    var pathPoints: [CoordinatePair]?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        start: CoordinatePair,
        end: CoordinatePair,
        travelMode: RouteTravelMode,
        speedKilometersPerHour: Double,
        offsetMeters: Double,
        repeatMode: RouteRepeatMode,
        viaPoints: [CoordinatePair] = [],
        pathPoints: [CoordinatePair]?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.travelMode = travelMode
        self.speedKilometersPerHour = speedKilometersPerHour
        self.offsetMeters = offsetMeters
        self.repeatMode = repeatMode
        self.viaPoints = viaPoints
        self.pathPoints = pathPoints
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, start, end, travelMode, speedKilometersPerHour
        case offsetMeters, repeatMode, viaPoints, pathPoints, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        start = try container.decode(CoordinatePair.self, forKey: .start)
        end = try container.decode(CoordinatePair.self, forKey: .end)
        travelMode = try container.decode(RouteTravelMode.self, forKey: .travelMode)
        speedKilometersPerHour = try container.decode(Double.self, forKey: .speedKilometersPerHour)
        offsetMeters = try container.decode(Double.self, forKey: .offsetMeters)
        repeatMode = try container.decode(RouteRepeatMode.self, forKey: .repeatMode)
        viaPoints = try container.decodeIfPresent([CoordinatePair].self, forKey: .viaPoints) ?? []
        pathPoints = try container.decodeIfPresent([CoordinatePair].self, forKey: .pathPoints)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(travelMode, forKey: .travelMode)
        try container.encode(speedKilometersPerHour, forKey: .speedKilometersPerHour)
        try container.encode(offsetMeters, forKey: .offsetMeters)
        try container.encode(repeatMode, forKey: .repeatMode)
        try container.encode(viaPoints, forKey: .viaPoints)
        try container.encodeIfPresent(pathPoints, forKey: .pathPoints)
        try container.encode(createdAt, forKey: .createdAt)
    }

    var distanceMeters: Double {
        if let pathPoints, pathPoints.count >= 2 {
            return RoutePath.make(pathPoints).totalMeters
        }
        return RoutePlayback.distanceMeters(along: [start] + viaPoints + [end])
    }

    var summaryText: String {
        var parts = [travelMode.displayName, repeatMode.displayName]
        if !viaPoints.isEmpty {
            parts.append("\(viaPoints.count) 个途经")
        }
        parts.append(RoutePlayback.formattedDistance(distanceMeters))
        return parts.joined(separator: " · ")
    }
}

final class SavedRouteStore: ObservableObject {
    static let limit = 20

    private enum Keys {
        static let routes = "saved_routes_v1"
    }

    @Published private(set) var routes: [SavedRoute]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.routes),
           let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) {
            routes = Array(decoded.prefix(Self.limit))
        } else {
            routes = []
        }
    }

    @discardableResult
    func save(_ route: SavedRoute) -> SavedRoute {
        var next = routes.filter { $0.id != route.id }
        next.insert(route, at: 0)
        if next.count > Self.limit {
            next = Array(next.prefix(Self.limit))
        }
        routes = next
        persistIgnoringFailure()
        return route
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].name = name
        persistIgnoringFailure()
    }

    func delete(_ route: SavedRoute) {
        routes = routes.filter { $0.id != route.id }
        persistIgnoringFailure()
    }

    private func persistIgnoringFailure() {
        do {
            try persist()
        } catch {
            RuntimeLogger.error("APP", "路线", "保存路线失败", error: error)
        }
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(routes), forKey: Keys.routes)
    }
}
