import Foundation

enum IslandFavoriteShortcuts {
    static let limitWithoutSwitch = 2
    static let limitWithSwitch = 1

    @MainActor
    static func performSwitch(
        to favorite: FavoriteLocation,
        action: String,
        apply: (FavoriteLocation) -> Void,
        reject: (String, String) -> Void
    ) {
        do {
            try LocationAccuracy.validatedCInt(favorite.accuracy)
        } catch {
            // 必须早于选点和停止走动，重试也保留原收藏，不能悄悄换成全局精度。
            reject(action, error.localizedDescription)
            return
        }
        apply(favorite)
    }

    static func pick(
        from displayed: [FavoriteLocation],
        selectedID: UUID?,
        writtenLatitude: Double?,
        writtenLongitude: Double?,
        currentSelection: CoordinatePair,
        needsSwitch: Bool
    ) -> [FavoriteLocation] {
        let limit = needsSwitch ? limitWithSwitch : limitWithoutSwitch
        let remaining = displayed.filter { favorite in
            if isCurrentSpoof(
                favorite,
                writtenLatitude: writtenLatitude,
                writtenLongitude: writtenLongitude
            ) {
                return false
            }
            if needsSwitch, favorite.coordinatePair.matchesWGS84(
                latitude: currentSelection.wgs84.latitude,
                longitude: currentSelection.wgs84.longitude
            ) {
                return false
            }
            return true
        }
        var picked: [FavoriteLocation] = []
        if let selectedID, let selected = remaining.first(where: { $0.id == selectedID }) {
            picked.append(selected)
        }
        for favorite in remaining where picked.count < limit {
            if picked.contains(where: { $0.id == favorite.id }) { continue }
            picked.append(favorite)
        }
        return picked
    }

    private static func isCurrentSpoof(
        _ favorite: FavoriteLocation,
        writtenLatitude: Double?,
        writtenLongitude: Double?
    ) -> Bool {
        guard let writtenLatitude, let writtenLongitude else { return false }
        return favorite.coordinatePair.matchesWGS84(
            latitude: writtenLatitude,
            longitude: writtenLongitude
        )
    }
}
