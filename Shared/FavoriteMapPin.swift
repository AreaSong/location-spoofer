import CoreLocation
import Foundation

struct FavoriteMapPin: Equatable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let isSelected: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func pins(
        from favorites: [FavoriteLocation],
        selectedID: UUID?,
        mapSystem: CoordinateConverter.MapCoordinateSystem
    ) -> [FavoriteMapPin] {
        favorites.map { favorite in
            let coordinate = favorite.coordinatePair.coordinate(for: mapSystem)
            return FavoriteMapPin(
                id: favorite.id,
                name: favorite.name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                isSelected: favorite.id == selectedID
            )
        }
    }
}
