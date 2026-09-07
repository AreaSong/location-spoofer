import Combine
import CoreLocation
import Foundation

struct RecentSelection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var coordinatePair: CoordinatePair

    init(id: UUID = UUID(), name: String, coordinatePair: CoordinatePair) {
        self.id = id
        self.name = name
        self.coordinatePair = coordinatePair
    }
}

final class RecentSelectionStore: ObservableObject {
    static let shared = RecentSelectionStore()
    static let limit = 10

    private enum Keys {
        static let items = "recent_map_selections_v1"
    }

    @Published private(set) var items: [RecentSelection]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.items),
           let decoded = try? JSONDecoder().decode([RecentSelection].self, from: data) {
            items = Array(decoded.prefix(Self.limit))
        } else {
            items = []
        }
    }

    func record(name: String, coordinatePair: CoordinatePair) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", coordinatePair.wgs84.latitude, coordinatePair.wgs84.longitude)
            : trimmed
        var next = items.filter { !isSameWGS84($0.coordinatePair, coordinatePair) }
        next.insert(RecentSelection(name: resolvedName, coordinatePair: coordinatePair), at: 0)
        if next.count > Self.limit {
            next = Array(next.prefix(Self.limit))
        }
        items = next
        persist()
    }

    func remove(_ item: RecentSelection) {
        items = items.filter { $0.id != item.id }
        persist()
    }

    func updateNameIfPresent(for coordinatePair: CoordinatePair, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { isSameWGS84($0.coordinatePair, coordinatePair) }) else {
            return
        }
        guard items[index].name != trimmed else { return }
        var next = items
        next[index].name = trimmed
        items = next
        persist()
    }

    private func isSameWGS84(_ lhs: CoordinatePair, _ rhs: CoordinatePair) -> Bool {
        abs(lhs.wgs84.latitude - rhs.wgs84.latitude) < 0.000001
            && abs(lhs.wgs84.longitude - rhs.wgs84.longitude) < 0.000001
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Keys.items)
    }
}
