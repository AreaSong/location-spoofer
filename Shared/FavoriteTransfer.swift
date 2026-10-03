import Foundation

enum FavoriteTransfer {
    static let format = "paopao-favorites"
    static let version = 1

    struct MergeResult: Equatable {
        var added: Int
        var updated: Int
        var skippedDuplicates: Int
        var skippedOverLimit: Int
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
        let formatter = makeDateFormatter(fractional: true)
        let document = Document(
            format: format,
            version: version,
            favorites: favorites.map { item(from: $0, formatter: formatter) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func decode(
        _ data: Data,
        checkpoint: () throws -> Void = {}
    ) throws -> [FavoriteLocation] {
        try checkpoint()
        let decoder = JSONDecoder()
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            throw TransferError.invalidJSON
        }
        try checkpoint()
        guard document.format == format, document.version == version else {
            throw TransferError.unsupportedFormat
        }
        guard !document.favorites.isEmpty else {
            throw TransferError.empty
        }
        let formatter = makeDateFormatter(fractional: true)
        let fallback = makeDateFormatter(fractional: false)
        return try document.favorites.map {
            try checkpoint()
            return try favorite(from: $0, formatter: formatter, fallback: fallback)
        }
    }

    static func decode(text: String) throws -> [FavoriteLocation] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw TransferError.invalidJSON
        }
        return try decode(data)
    }

    private static func item(from favorite: FavoriteLocation, formatter: ISO8601DateFormatter) -> Item {
        Item(
            name: favorite.name,
            accuracy: favorite.accuracy,
            createdAt: formatter.string(from: favorite.createdAt),
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

    private static func favorite(
        from item: Item, formatter: ISO8601DateFormatter, fallback: ISO8601DateFormatter
    ) throws -> FavoriteLocation {
        try LocationAccuracy.validatedCInt(item.accuracy)
        guard let wgs84 = item.wgs84,
              let gcj02 = item.gcj02,
              isValidLatitude(wgs84.latitude),
              isValidLongitude(wgs84.longitude),
              isValidLatitude(gcj02.latitude),
              isValidLongitude(gcj02.longitude) else {
            throw TransferError.missingCoordinates
        }
        let createdAt = formatter.date(from: item.createdAt)
            ?? fallback.date(from: item.createdAt)
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

    private static func makeDateFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    /// 只能通过整批预检构造；提交方无需重新执行批内查重。
    struct Prepared {
        let favorites: [FavoriteLocation]
        let skippedDuplicates: Int

        fileprivate init(favorites: [FavoriteLocation], skippedDuplicates: Int) {
            self.favorites = favorites
            self.skippedDuplicates = skippedDuplicates
        }
    }

    static func prepare(
        _ incoming: [FavoriteLocation], checkpoint: () throws -> Void = {}
    ) throws -> Prepared {
        for item in incoming {
            try checkpoint()
            try LocationAccuracy.validatedCInt(item.accuracy)
            let pair = item.coordinatePair
            guard isValidLatitude(pair.wgs84.latitude), isValidLongitude(pair.wgs84.longitude),
                  isValidLatitude(pair.gcj02.latitude), isValidLongitude(pair.gcj02.longitude) else {
                throw TransferError.missingCoordinates
            }
        }
        var unique: [FavoriteLocation] = []
        for item in incoming {
            try checkpoint()
            var match: Int?
            for index in unique.indices {
                // 大批量线性扫描也能响应取消，不改变 firstIndex 的顺序语义。
                if index % 256 == 0 { try checkpoint() }
                if isSameWGS84(unique[index], item) { match = index; break }
            }
            if let index = match {
                unique[index].name = item.name
                unique[index].coordinatePair = item.coordinatePair
                unique[index].accuracy = item.accuracy
            } else {
                unique.append(item)
            }
        }
        try checkpoint()
        return Prepared(favorites: unique, skippedDuplicates: incoming.count - unique.count)
    }

    static func isSameWGS84(_ lhs: FavoriteLocation, _ rhs: FavoriteLocation) -> Bool {
        abs(lhs.coordinatePair.wgs84.latitude - rhs.coordinatePair.wgs84.latitude) < 0.000001
            && abs(lhs.coordinatePair.wgs84.longitude - rhs.coordinatePair.wgs84.longitude) < 0.000001
    }
}
