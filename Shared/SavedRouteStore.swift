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
    /// 规划降级。旧存档没有这个字段，加载后不显示直线提示。
    var straightFallback: RoutePathFallback?
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
        straightFallback: RoutePathFallback? = nil,
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
        self.straightFallback = straightFallback
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, start, end, travelMode, speedKilometersPerHour
        case offsetMeters, repeatMode, viaPoints, pathPoints, straightFallback, createdAt
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
        straightFallback = try container.decodeIfPresent(RoutePathFallback.self, forKey: .straightFallback)
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
        try container.encodeIfPresent(straightFallback, forKey: .straightFallback)
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
    private let pathStore: RoutePathFileStore

    init(defaults: UserDefaults = AppGroup.defaults, pathDirectory: URL? = nil) {
        let pathStore = RoutePathFileStore(directory: pathDirectory ?? RoutePathFileStore.defaultDirectory)
        self.defaults = defaults
        self.pathStore = pathStore
        let decoded = Self.loadCatalog(defaults)
        let kept = Array(decoded.prefix(Self.limit))
        let dropped = decoded.dropFirst(Self.limit)
        dropped.forEach { pathStore.delete($0.id) }
        let hadEmbeddedPath = kept.contains { ($0.pathPoints?.count ?? 0) >= 2 }
        let hydrated = kept.map { Self.hydrate($0, pathStore: pathStore) }
        routes = hydrated
        if hadEmbeddedPath {
            persistIgnoringFailure()
        }
    }

    @discardableResult
    func save(_ route: SavedRoute) -> SavedRoute {
        pathStore.write(route)
        var stored = route
        stored.pathPoints = pathStore.read(matching: route) ?? route.pathPoints
        var next = routes.filter { $0.id != stored.id }
        next.insert(stored, at: 0)
        if next.count > Self.limit {
            next.suffix(from: Self.limit).forEach { pathStore.delete($0.id) }
            next = Array(next.prefix(Self.limit))
        }
        routes = next
        persistIgnoringFailure()
        return stored
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].name = name
        persistIgnoringFailure()
    }

    func delete(_ route: SavedRoute) {
        pathStore.delete(route.id)
        routes = routes.filter { $0.id != route.id }
        persistIgnoringFailure()
    }

    func exportTransferred() throws -> Data {
        try RouteTransfer.encode(routes)
    }

    @discardableResult
    func importTransferred(_ incoming: [SavedRoute]) -> RouteTransfer.MergeResult {
        var added = 0
        var updated = 0
        var skippedOverLimit = 0
        var next = routes
        for item in incoming {
            if let index = next.firstIndex(where: { $0.id == item.id || sameGeometry($0, item) }) {
                var merged = item
                if next[index].id != item.id {
                    merged = replacing(item, id: next[index].id, createdAt: next[index].createdAt)
                }
                pathStore.delete(next[index].id)
                pathStore.write(merged)
                var stored = merged
                stored.pathPoints = pathStore.read(matching: merged)
                next[index] = stored
                updated += 1
            } else if next.count >= Self.limit {
                skippedOverLimit += 1
            } else {
                pathStore.write(item)
                var stored = item
                stored.pathPoints = pathStore.read(matching: item)
                next.insert(stored, at: 0)
                added += 1
            }
        }
        routes = next
        persistIgnoringFailure()
        return RouteTransfer.MergeResult(added: added, updated: updated, skippedOverLimit: skippedOverLimit)
    }

    private func sameGeometry(_ lhs: SavedRoute, _ rhs: SavedRoute) -> Bool {
        lhs.travelMode == rhs.travelMode
            && lhs.viaPoints.count == rhs.viaPoints.count
            && samePoint(lhs.start, rhs.start)
            && samePoint(lhs.end, rhs.end)
            && zip(lhs.viaPoints, rhs.viaPoints).allSatisfy { samePoint($0, $1) }
    }

    private func samePoint(_ lhs: CoordinatePair, _ rhs: CoordinatePair) -> Bool {
        abs(lhs.wgs84.latitude - rhs.wgs84.latitude) < 0.000001
            && abs(lhs.wgs84.longitude - rhs.wgs84.longitude) < 0.000001
    }

    private func replacing(_ route: SavedRoute, id: UUID, createdAt: Date) -> SavedRoute {
        SavedRoute(
            id: id,
            name: route.name,
            start: route.start,
            end: route.end,
            travelMode: route.travelMode,
            speedKilometersPerHour: route.speedKilometersPerHour,
            offsetMeters: route.offsetMeters,
            repeatMode: route.repeatMode,
            viaPoints: route.viaPoints,
            pathPoints: route.pathPoints,
            straightFallback: route.straightFallback,
            createdAt: createdAt
        )
    }

    private static func hydrate(_ route: SavedRoute, pathStore: RoutePathFileStore) -> SavedRoute {
        var copy = route
        if let embedded = copy.pathPoints, embedded.count >= 2 {
            pathStore.write(copy)
        }
        copy.pathPoints = pathStore.read(matching: route)
        return copy
    }

    private static func loadCatalog(_ defaults: UserDefaults) -> [SavedRoute] {
        guard let data = defaults.data(forKey: Keys.routes),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            return []
        }
        return decoded
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
