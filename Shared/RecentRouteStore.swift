import Foundation

struct RecentRoute: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var start: CoordinatePair
    var end: CoordinatePair
    var viaPoints: [CoordinatePair]
    var travelMode: RouteTravelMode
    var speedKilometersPerHour: Double
    var offsetMeters: Double
    var repeatMode: RouteRepeatMode
    var updatedAt: Date

    func savedRoute() -> SavedRoute {
        SavedRoute(
            id: id,
            name: name,
            start: start,
            end: end,
            travelMode: travelMode,
            speedKilometersPerHour: speedKilometersPerHour,
            offsetMeters: offsetMeters,
            repeatMode: repeatMode,
            viaPoints: viaPoints,
            pathPoints: nil,
            createdAt: updatedAt
        )
    }
}

final class RecentRouteStore: ObservableObject {
    static let limit = 8

    private enum Keys {
        static let routes = "recent_routes_v1"
    }

    @Published private(set) var routes: [RecentRoute]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.routes),
           let decoded = try? JSONDecoder().decode([RecentRoute].self, from: data) {
            routes = Array(decoded.prefix(Self.limit))
        } else {
            routes = []
        }
    }

    func record(
        name: String,
        start: CoordinatePair,
        end: CoordinatePair,
        viaPoints: [CoordinatePair],
        travelMode: RouteTravelMode,
        speedKilometersPerHour: Double,
        offsetMeters: Double,
        repeatMode: RouteRepeatMode
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = routes.filter { !sameGeometry($0, start: start, end: end, vias: viaPoints, mode: travelMode) }
        next.insert(RecentRoute(
            id: UUID(),
            name: trimmed.isEmpty ? travelMode.displayName : trimmed,
            start: start,
            end: end,
            viaPoints: viaPoints,
            travelMode: travelMode,
            speedKilometersPerHour: speedKilometersPerHour,
            offsetMeters: offsetMeters,
            repeatMode: repeatMode,
            updatedAt: Date()
        ), at: 0)
        if next.count > Self.limit {
            next = Array(next.prefix(Self.limit))
        }
        routes = next
        persist()
    }

    private func sameGeometry(
        _ route: RecentRoute,
        start: CoordinatePair,
        end: CoordinatePair,
        vias: [CoordinatePair],
        mode: RouteTravelMode
    ) -> Bool {
        route.travelMode == mode
            && route.viaPoints.count == vias.count
            && same(route.start, start)
            && same(route.end, end)
            && zip(route.viaPoints, vias).allSatisfy { same($0, $1) }
    }

    private func same(_ lhs: CoordinatePair, _ rhs: CoordinatePair) -> Bool {
        abs(lhs.wgs84.latitude - rhs.wgs84.latitude) < 0.000001
            && abs(lhs.wgs84.longitude - rhs.wgs84.longitude) < 0.000001
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        defaults.set(data, forKey: Keys.routes)
    }
}
