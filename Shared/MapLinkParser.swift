import Foundation
import CoreLocation

enum MapLinkParser {
    struct ParsedLink: Equatable {
        let latitude: Double
        let longitude: Double
        let name: String?
        let sourceName: String
        let inferredSystem: CoordinateConverter.MapCoordinateSystem
    }

    static func parse(_ text: String) -> ParsedLink? {
        guard let url = extractURL(from: text) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let scheme = url.scheme?.lowercased() ?? ""

        if scheme == "maps" || host.contains("maps.apple.com") {
            return parseApple(url)
        }
        if host.contains("amap.com") || host.hasSuffix("uri.amap.com") || scheme == "iosamap" {
            return parseAmap(url)
        }
        if host.contains("google.") || host == "maps.google.com" {
            return parseGoogle(url)
        }
        if host.contains("map.baidu.com") || scheme == "baidumap" {
            return parseBaidu(url)
        }
        if host.contains("map.qq.com") || scheme == "qqmap" {
            return parseTencent(url)
        }
        return nil
    }

    private static func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        let lower = trimmed.lowercased()
        for marker in ["https://", "http://", "maps:", "iosamap://", "baidumap://", "qqmap://"] {
            guard let range = lower.range(of: marker) else { continue }
            let token = trimmed[range.lowerBound...]
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? String(trimmed[range.lowerBound...])
            if let url = URL(string: token) {
                return url
            }
        }
        return nil
    }

    private static func parseApple(_ url: URL) -> ParsedLink? {
        let items = queryItems(url)
        if let coordinate = coordinate(from: items["ll"]) ?? coordinate(from: items["q"]) {
            return ParsedLink(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: placeName(from: items["q"]),
                sourceName: "苹果地图",
                inferredSystem: .wgs84
            )
        }
        return nil
    }

    private static func parseGoogle(_ url: URL) -> ParsedLink? {
        let items = queryItems(url)
        if let coordinate = coordinate(from: items["q"])
            ?? coordinate(from: items["query"])
            ?? coordinate(from: items["ll"])
            ?? atCoordinate(in: url) {
            return ParsedLink(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: placeName(from: items["q"] ?? items["query"]),
                sourceName: "谷歌地图",
                inferredSystem: .wgs84
            )
        }
        return nil
    }

    private static func parseAmap(_ url: URL) -> ParsedLink? {
        let items = queryItems(url)
        guard let position = items["position"] ?? items["coordinate"] ?? items["poiLocation"] else {
            return nil
        }
        let parts = position
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        guard parts.count >= 2,
              let longitude = Double(parts[0]),
              let latitude = Double(parts[1]),
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else {
            return nil
        }
        return ParsedLink(
            latitude: latitude,
            longitude: longitude,
            name: placeName(from: items["name"] ?? items["poiname"]),
            sourceName: "高德",
            inferredSystem: .gcj02
        )
    }

    private static func parseBaidu(_ url: URL) -> ParsedLink? {
        let items = queryItems(url)
        guard let basis = baiduBasis(items),
              let coordinate = baiduCoordinate(items) else {
            return nil
        }
        return makeLink(
            coordinate: coordinate,
            basis: basis,
            name: placeName(from: items, keys: ["title", "name", "poiname"]),
            sourceName: "百度地图"
        )
    }

    private static func parseTencent(_ url: URL) -> ParsedLink? {
        let items = queryItems(url)
        guard let coordinate = tencentCoordinate(items) else { return nil }
        return makeLink(
            coordinate: coordinate,
            basis: .gcj02,
            name: placeName(from: items, keys: ["title", "name", "poiname"])
                ?? tencentMarkerField(items["marker"], key: "title"),
            sourceName: "腾讯地图"
        )
    }

    private enum CoordinateBasis {
        case wgs84
        case gcj02
        case bd09
    }

    private static func makeLink(
        coordinate: (latitude: Double, longitude: Double),
        basis: CoordinateBasis,
        name: String?,
        sourceName: String
    ) -> ParsedLink {
        switch basis {
        case .wgs84:
            return ParsedLink(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: name,
                sourceName: sourceName,
                inferredSystem: .wgs84
            )
        case .gcj02:
            return ParsedLink(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: name,
                sourceName: sourceName,
                inferredSystem: .gcj02
            )
        case .bd09:
            let gcj = CoordinateConverter.bd09ToGcj02(
                lat: coordinate.latitude,
                lon: coordinate.longitude
            )
            return ParsedLink(
                latitude: gcj.lat,
                longitude: gcj.lon,
                name: name,
                sourceName: sourceName,
                inferredSystem: .gcj02
            )
        }
    }

    private static func baiduBasis(_ items: [String: String]) -> CoordinateBasis? {
        let raw = (items["coord_type"] ?? items["coordtype"] ?? "bd09ll").lowercased()
        if raw.contains("mc") { return nil }
        if raw.contains("wgs") { return .wgs84 }
        if raw.contains("gcj") { return .gcj02 }
        return .bd09
    }

    private static func baiduCoordinate(_ items: [String: String]) -> (latitude: Double, longitude: Double)? {
        coordinate(from: items["latlng"])
            ?? coordinate(from: items["location"])
            ?? separateLatLon(items)
    }

    private static func tencentCoordinate(_ items: [String: String]) -> (latitude: Double, longitude: Double)? {
        if let latitude = Double(items["pointy"] ?? ""),
           let longitude = Double(items["pointx"] ?? ""),
           isLatitude(latitude), isLongitude(longitude) {
            return (latitude, longitude)
        }
        return separateLatLon(items)
            ?? coordinate(from: items["coord"])
            ?? coordinate(from: items["center"])
            ?? coordinate(from: items["ll"])
            ?? coordinate(from: tencentMarkerField(items["marker"], key: "coord"))
    }

    private static func separateLatLon(_ items: [String: String]) -> (latitude: Double, longitude: Double)? {
        let latitudeRaw = items["lat"] ?? items["latitude"] ?? items["pointy"]
        let longitudeRaw = items["lng"] ?? items["lon"] ?? items["longitude"] ?? items["pointx"]
        guard let latitude = latitudeRaw.flatMap(Double.init),
              let longitude = longitudeRaw.flatMap(Double.init),
              isLatitude(latitude), isLongitude(longitude) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func tencentMarkerField(_ raw: String?, key: String) -> String? {
        guard let raw else { return nil }
        for part in raw.split(separator: ";") {
            let token = String(part)
            guard let colon = token.firstIndex(of: ":") else { continue }
            let field = token[..<colon]
            if field.lowercased() == key {
                let value = String(token[token.index(after: colon)...])
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func atCoordinate(in url: URL) -> (latitude: Double, longitude: Double)? {
        let path = url.path + (url.fragment.map { "/\($0)" } ?? "")
        guard let at = path.range(of: "@") else { return nil }
        let rest = path[at.upperBound...]
        let token = rest.split(separator: "/").first.map(String.init) ?? String(rest)
        let parts = token.split(separator: ",")
        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              isLatitude(latitude), isLongitude(longitude) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func coordinate(from raw: String?) -> (latitude: Double, longitude: Double)? {
        guard let raw, let parsed = CoordinateTextParser.parse(raw) else { return nil }
        return (parsed.latitude, parsed.longitude)
    }

    private static func placeName(from items: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let name = placeName(from: items[key]) { return name }
        }
        return nil
    }

    private static func placeName(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CoordinateTextParser.parse(trimmed) == nil else { return nil }
        return trimmed
    }

    private static func isLatitude(_ value: Double) -> Bool {
        value >= -90 && value <= 90
    }

    private static func isLongitude(_ value: Double) -> Bool {
        value >= -180 && value <= 180
    }

    private static func queryItems(_ url: URL) -> [String: String] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.query == nil, let fragment = url.fragment, fragment.contains("=") {
            components = URLComponents(string: "https://placeholder.local?\(fragment)")
        }
        let items = components?.queryItems ?? []
        return Dictionary(items.compactMap { item in
            guard let value = item.value, !value.isEmpty else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { _, last in last })
    }
}
