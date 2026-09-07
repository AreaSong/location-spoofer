import Foundation

enum FavoriteTransfer {
    static let format = "paopao-favorites"
    static let version = 1

    struct MergeResult: Equatable {
        var added: Int
        var updated: Int
    }

    enum TransferError: LocalizedError, Equatable {
        case invalidJSON
        case unsupportedFormat
        case empty
        case missingCoordinates

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "收藏备份不是有效的 JSON"
            case .unsupportedFormat:
                return "不支持的收藏备份格式"
            case .empty:
                return "备份里没有可导入的收藏"
            case .missingCoordinates:
                return "收藏备份缺少完整的 WGS-84 / GCJ-02 坐标"
            }
        }
    }

    struct Document: Codable, Equatable {
        var format: String
        var version: Int
        var favorites: [Item]
    }

    struct Item: Codable, Equatable {
        var name: String
        var accuracy: Int
        var createdAt: String
        var wgs84: Coordinate?
        var gcj02: Coordinate?
    }

    struct Coordinate: Codable, Equatable {
        var latitude: Double
        var longitude: Double
    }

    static func encode(_ favorites: [FavoriteLocation]) throws -> Data {
        let document = Document(
            format: format,
            version: version,
            favorites: favorites.map(item(from:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> [FavoriteLocation] {
        let decoder = JSONDecoder()
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw TransferError.invalidJSON
        }
        guard document.format == format, document.version == version else {
            throw TransferError.unsupportedFormat
        }
        guard !document.favorites.isEmpty else {
            throw TransferError.empty
        }
        return try document.favorites.map(favorite(from:))
    }

    static func decode(text: String) throws -> [FavoriteLocation] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw TransferError.invalidJSON
        }
        return try decode(data)
    }

    private static func item(from favorite: FavoriteLocation) -> Item {
        Item(
            name: favorite.name,
            accuracy: favorite.accuracy,
            createdAt: dateFormatter.string(from: favorite.createdAt),
            wgs84: Coordinate(
                latitude: favorite.coordinatePair.wgs84.latitude,
                longitude: favorite.coordinatePair.wgs84.longitude
            ),
            gcj02: Coordinate(
                latitude: favorite.coordinatePair.gcj02.latitude,
                longitude: favorite.coordinatePair.gcj02.longitude
            )
        )
    }

    private static func favorite(from item: Item) throws -> FavoriteLocation {
        guard let wgs84 = item.wgs84,
              let gcj02 = item.gcj02,
              isValidLatitude(wgs84.latitude),
              isValidLongitude(wgs84.longitude),
              isValidLatitude(gcj02.latitude),
              isValidLongitude(gcj02.longitude) else {
            throw TransferError.missingCoordinates
        }
        let createdAt = dateFormatter.date(from: item.createdAt)
            ?? fallbackDateFormatter.date(from: item.createdAt)
            ?? Date()
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return FavoriteLocation(
            name: name.isEmpty ? "未命名地点" : name,
            coordinatePair: CoordinatePair(
                wgs84: .init(latitude: wgs84.latitude, longitude: wgs84.longitude),
                gcj02: .init(latitude: gcj02.latitude, longitude: gcj02.longitude)
            ),
            accuracy: item.accuracy,
            createdAt: createdAt
        )
    }

    private static func isValidLatitude(_ value: Double) -> Bool {
        value >= -90 && value <= 90
    }

    private static func isValidLongitude(_ value: Double) -> Bool {
        value >= -180 && value <= 180
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
