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
    static let limit = 50

    private enum Keys {
        static let routes = "saved_routes_v1"
    }

    @Published private(set) var routes: [SavedRoute]
    private let defaults: UserDefaults
    private let pathStore: RoutePathFileStore

    private var migrationPending = false

    init(
        defaults: UserDefaults = AppGroup.defaults,
        pathDirectory: URL? = nil,
        beforePathDelete: @escaping (UUID) throws -> Void = { _ in },
        beforePathWrite: @escaping (UUID) throws -> Void = { _ in }
    ) {
        let pathStore = RoutePathFileStore(
            directory: pathDirectory ?? RoutePathFileStore.defaultDirectory,
            beforeDelete: beforePathDelete,
            beforeWrite: beforePathWrite
        )
        self.defaults = defaults
        self.pathStore = pathStore
        let decoded = Self.loadCatalog(defaults)
        routes = Array(decoded.prefix(Self.limit)).map { Self.hydrate($0, pathStore: pathStore) }
        migrationPending = decoded.contains { ($0.pathPoints?.count ?? 0) >= 2 }
        do { try finishMigration() } catch {
            RuntimeLogger.error("APP", "路线", "迁移路线失败，保留原目录以便重试", error: error)
        }
    }

    @discardableResult
    func save(_ route: SavedRoute) throws -> SavedRoute {
        try finishMigration()
        var next = routes.filter { $0.id != route.id }
        next.insert(route, at: 0)
        let dropped = Array(next.dropFirst(Self.limit))
        next = Array(next.prefix(Self.limit))
        let stored = try commit(route, at: 0, in: next)
        cleanup(dropped)
        return stored
    }

    func rename(_ id: UUID, to name: String) throws {
        try finishMigration()
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        var next = routes
        next[index].name = name
        try persist(next)
        routes = next
    }

    func delete(_ route: SavedRoute) throws {
        try finishMigration()
        let next = routes.filter { $0.id != route.id }
        try persist(next)
        routes = next
        cleanup([route])
    }

    func exportTransferred() throws -> Data {
        try RouteTransfer.encode(routes)
    }

    @discardableResult
    func importTransferred(_ incoming: [SavedRoute]) -> RouteTransfer.MergeResult {
        var result = RouteTransfer.MergeResult(added: 0, updated: 0, skippedOverLimit: 0)
        for item in incoming {
            do {
                try finishMigration()
                var next = routes
                if let index = next.firstIndex(where: { $0.id == item.id || sameGeometry($0, item) }) {
                    let merged = next[index].id == item.id ? item
                        : replacing(item, id: next[index].id, createdAt: next[index].createdAt)
                    next[index] = merged
                    try commit(merged, at: index, in: next)
                    result.updated += 1
                } else if next.count >= Self.limit {
                    result.skippedOverLimit += 1
                } else {
                    next.insert(item, at: 0)
                    try commit(item, at: 0, in: next)
                    result.added += 1
                }
            } catch {
                result.failed += 1
                RuntimeLogger.error("APP", "路线", "导入路线失败", error: error)
            }
        }
        return result
    }

    @discardableResult
    private func commit(_ route: SavedRoute, at index: Int, in proposed: [SavedRoute]) throws -> SavedRoute {
        // 先验证目录可编码，避免路径已替换后才发现元数据无效。
        let catalog = try JSONEncoder().encode(proposed)
        var stored = route
        stored.pathPoints = try pathStore.write(route)
        var next = proposed
        next[index] = stored
        // UserDefaults 不提供持久化确认；这里不宣称跨文件崩溃事务保证。
        defaults.set(catalog, forKey: Keys.routes)
        routes = next
        return stored
    }

    private func finishMigration() throws {
        guard migrationPending else { return }
        let decoded = Self.loadCatalog(defaults)
        let kept = Array(decoded.prefix(Self.limit))
        let catalog = try JSONEncoder().encode(kept)
        var migrated = kept
        for index in kept.indices {
            if (kept[index].pathPoints?.count ?? 0) >= 2 {
                migrated[index].pathPoints = try pathStore.write(kept[index])
            } else {
                migrated[index] = Self.hydrate(kept[index], pathStore: pathStore)
            }
        }
        // 所有内嵌路径写入并回读验证后才移除旧目录中的恢复来源。
        defaults.set(catalog, forKey: Keys.routes)
        routes = migrated
        migrationPending = false
        cleanup(Array(decoded.dropFirst(Self.limit)))
    }

    private func cleanup(_ removed: [SavedRoute]) {
        for route in removed {
            do { try pathStore.delete(route.id) } catch {
                RuntimeLogger.error("APP", "路线", "清理未引用路径失败", error: error)
            }
        }
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
        if (copy.pathPoints?.count ?? 0) < 2 {
            copy.pathPoints = pathStore.read(matching: route)
        }
        return copy
    }

    private static func loadCatalog(_ defaults: UserDefaults) -> [SavedRoute] {
        guard let data = defaults.data(forKey: Keys.routes),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persist(_ next: [SavedRoute]) throws {
        defaults.set(try JSONEncoder().encode(next), forKey: Keys.routes)
    }
}
