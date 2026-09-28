import Foundation

enum RouteGPX {
    enum ParseError: LocalizedError, Equatable {
        case invalidXML
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidXML: return "GPX 文件不是有效的 XML"
            case .empty: return "GPX 里没有足够长的轨迹"
            }
        }
    }

    static func looksLikeGPX(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512).lowercased()
        return prefix.contains("<gpx")
    }

    static func decode(_ data: Data, fallbackName: String = "导入路线") throws -> [SavedRoute] {
        let collector = Collector(fallbackName: fallbackName)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        guard parser.parse() else { throw ParseError.invalidXML }
        let routes = collector.routes
        guard !routes.isEmpty else { throw ParseError.empty }
        return routes
    }
}

private final class Collector: NSObject, XMLParserDelegate {
    private let fallbackName: String
    private var inMetadata = false
    private var inPath = false
    private var capturingName = false
    private var nameBuffer = ""
    private var currentName: String?
    private var currentPoints: [CoordinatePair] = []
    private var waypoints: [CoordinatePair] = []
    private(set) var routes: [SavedRoute] = []

    init(fallbackName: String) {
        self.fallbackName = fallbackName
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        switch name {
        case "metadata":
            inMetadata = true
        case "trk", "rte":
            flushPath()
            inPath = true
            currentName = nil
            currentPoints = []
        case "name":
            capturingName = inPath && !inMetadata
            nameBuffer = ""
        case "trkpt", "rtept":
            if inPath, let point = coordinate(from: attributeDict) {
                append(point, to: &currentPoints)
            }
        case "wpt":
            if let point = coordinate(from: attributeDict) {
                append(point, to: &waypoints)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingName { nameBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        switch name {
        case "metadata":
            inMetadata = false
        case "name":
            if capturingName {
                let trimmed = nameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { currentName = trimmed }
            }
            capturingName = false
        case "trk", "rte":
            flushPath()
            inPath = false
        case "gpx":
            flushPath()
            if routes.isEmpty { flushWaypoints() }
        default:
            break
        }
    }

    private func flushPath() {
        defer {
            currentName = nil
            currentPoints = []
        }
        appendRoute(points: currentPoints, name: currentName)
    }

    private func flushWaypoints() {
        appendRoute(points: waypoints, name: nil)
    }

    private func appendRoute(points: [CoordinatePair], name: String?) {
        let simplified = RoutePathSimplifier.simplify(points)
        guard simplified.count >= 2,
              RoutePath.make(simplified).totalMeters >= RoutePlayback.minimumDistanceMeters else {
            return
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        routes.append(
            SavedRoute(
                name: trimmed.isEmpty ? fallbackName : trimmed,
                start: simplified[0],
                end: simplified[simplified.count - 1],
                travelMode: .walk,
                speedKilometersPerHour: RouteTravelMode.walk.kilometersPerHour,
                offsetMeters: 0,
                repeatMode: .once,
                viaPoints: [],
                pathPoints: simplified
            )
        )
    }

    private func append(_ point: CoordinatePair, to points: inout [CoordinatePair]) {
        if let last = points.last,
           RoutePlayback.distanceMeters(from: last, to: point) < 0.5 {
            return
        }
        points.append(point)
    }

    private func coordinate(from attributes: [String: String]) -> CoordinatePair? {
        guard let lat = Double(attributes["lat"] ?? ""),
              let lon = Double(attributes["lon"] ?? ""),
              lat >= -90, lat <= 90,
              lon >= -180, lon <= 180 else {
            return nil
        }
        return CoordinateConverter.coordinatePair(lat: lat, lon: lon, mapCoordinateSystem: .wgs84)
    }

    private func localName(_ raw: String) -> String {
        raw.split(separator: ":").last.map(String.init)?.lowercased() ?? raw.lowercased()
    }
}
