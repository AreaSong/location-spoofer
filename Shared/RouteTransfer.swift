import Foundation

enum RouteTransfer {
    static let format = "paopao-routes"
    static let version = 1

    struct MergeResult: Equatable {
        var added: Int
        var updated: Int
        var skippedOverLimit: Int
    }

    enum TransferError: LocalizedError, Equatable {
        case invalidJSON
        case unsupportedFormat
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "路线备份不是有效的 JSON"
            case .unsupportedFormat: return "不支持的路线备份格式"
            case .empty: return "备份里没有可导入的路线"
            }
        }
    }

    struct Document: Codable, Equatable {
        var format: String
        var version: Int
        var routes: [Item]
    }

    struct Item: Codable, Equatable {
        var id: UUID
        var name: String
        var travelMode: String
        var speedKilometersPerHour: Double
        var offsetMeters: Double
        var repeatMode: String
        var createdAt: String
        var start: FavoriteTransfer.Coordinate
        var end: FavoriteTransfer.Coordinate
        var vias: [FavoriteTransfer.Coordinate]
        var path: [FavoriteTransfer.Coordinate]?
    }

    static func encode(_ routes: [SavedRoute]) throws -> Data {
        let document = Document(format: format, version: version, routes: routes.map(item(from:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> [SavedRoute] {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw TransferError.invalidJSON
        }
        guard document.format == format, document.version == version else {
            throw TransferError.unsupportedFormat
        }
        guard !document.routes.isEmpty else { throw TransferError.empty }
        return try document.routes.map(route(from:))
    }

    static func decode(text: String) throws -> [SavedRoute] {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw TransferError.invalidJSON
        }
        return try decode(data)
    }

    private static func item(from route: SavedRoute) -> Item {
        Item(
            id: route.id,
            name: route.name,
            travelMode: route.travelMode.rawValue,
            speedKilometersPerHour: route.speedKilometersPerHour,
            offsetMeters: route.offsetMeters,
            repeatMode: route.repeatMode.rawValue,
            createdAt: dateFormatter.string(from: route.createdAt),
            start: coordinate(route.start),
            end: coordinate(route.end),
            vias: route.viaPoints.map(coordinate),
            path: route.pathPoints.map { RoutePathSimplifier.simplify($0).map(coordinate) }
        )
    }

    private static func route(from item: Item) throws -> SavedRoute {
        guard let travelMode = RouteTravelMode(rawValue: item.travelMode),
              let repeatMode = RouteRepeatMode(rawValue: item.repeatMode) else {
            throw TransferError.invalidJSON
        }
        return SavedRoute(
            id: item.id,
            name: item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名路线" : item.name,
            start: try pair(item.start),
            end: try pair(item.end),
            travelMode: travelMode,
            speedKilometersPerHour: item.speedKilometersPerHour,
            offsetMeters: item.offsetMeters,
            repeatMode: repeatMode,
            viaPoints: try item.vias.map(pair),
            pathPoints: try item.path.map { try $0.map(pair) },
            createdAt: dateFormatter.date(from: item.createdAt) ?? Date()
        )
    }

    private static func coordinate(_ pair: CoordinatePair) -> FavoriteTransfer.Coordinate {
        FavoriteTransfer.Coordinate(latitude: pair.wgs84.latitude, longitude: pair.wgs84.longitude)
    }

    private static func pair(_ coordinate: FavoriteTransfer.Coordinate) throws -> CoordinatePair {
        guard coordinate.latitude >= -90, coordinate.latitude <= 90,
              coordinate.longitude >= -180, coordinate.longitude <= 180 else {
            throw TransferError.invalidJSON
        }
        return CoordinateConverter.coordinatePair(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            mapCoordinateSystem: .wgs84
        )
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
