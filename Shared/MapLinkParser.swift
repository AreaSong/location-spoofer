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
        return nil
    }

    private static func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        let lower = trimmed.lowercased()
        for marker in ["https://", "http://", "maps:", "iosamap://"] {
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

    private static func atCoordinate(in url: URL) -> (latitude: Double, longitude: Double)? {
        let path = url.path + (url.fragment.map { "/\($0)" } ?? "")
        guard let at = path.range(of: "@") else { return nil }
        let rest = path[at.upperBound...]
        let token = rest.split(separator: "/").first.map(String.init) ?? String(rest)
        let parts = token.split(separator: ",")
        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]),
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func coordinate(from raw: String?) -> (latitude: Double, longitude: Double)? {
        guard let raw, let parsed = CoordinateTextParser.parse(raw) else { return nil }
        return (parsed.latitude, parsed.longitude)
    }

    private static func placeName(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CoordinateTextParser.parse(trimmed) == nil else { return nil }
        return trimmed
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
