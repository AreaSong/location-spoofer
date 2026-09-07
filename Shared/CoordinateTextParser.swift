import Foundation

enum CoordinateTextParser {
    struct ParsedCoordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    static func parse(_ text: String) -> ParsedCoordinate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "/", with: ",")
            .replacingOccurrences(of: "\\", with: ",")
        let parts = normalized
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              let first = Double(parts[0]),
              let second = Double(parts[1]) else {
            return nil
        }

        if isLatitude(first), isLongitude(second) {
            return ParsedCoordinate(latitude: first, longitude: second)
        }
        if abs(first) > 90, isLongitude(first), isLatitude(second) {
            return ParsedCoordinate(latitude: second, longitude: first)
        }
        return nil
    }

    private static func isLatitude(_ value: Double) -> Bool {
        value >= -90 && value <= 90
    }

    private static func isLongitude(_ value: Double) -> Bool {
        value >= -180 && value <= 180
    }
}
