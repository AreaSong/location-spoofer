import Foundation

enum RouteKML {
    enum ParseError: LocalizedError, Equatable {
        case invalidXML
        case empty
        case unsupportedArchive

        var errorDescription: String? {
            switch self {
            case .invalidXML: return "KML 文件不是有效的 XML"
            case .empty: return "KML 里没有足够长的轨迹"
            case .unsupportedArchive: return "暂不支持 KMZ 压缩包，请解压后导入 KML"
            }
        }
    }

    static func looksLikeKML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512).lowercased()
        return prefix.contains("<kml")
    }

    static func looksLikeKMZ(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B])
    }

    static func decode(_ data: Data, fallbackName: String = "导入路线") throws -> [SavedRoute] {
        if looksLikeKMZ(data) { throw ParseError.unsupportedArchive }
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
    private var inPlacemark = false
    private var inLineString = false
    private var inPoint = false
    private var inTrack = false
    private var capturingName = false
    private var capturingCoordinates = false
    private var capturingCoord = false
    private var nameBuffer = ""
    private var textBuffer = ""
    private var currentName: String?
    private var pathPoints: [CoordinatePair] = []
    private var pointPoints: [CoordinatePair] = []
    private var loosePoints: [CoordinatePair] = []
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
        switch localName(elementName, qualifiedName: qName) {
        case "placemark":
            flushPlacemark()
            inPlacemark = true
        case "linestring":
            inLineString = true
        case "point":
            inPoint = true
        case "track":
            inTrack = true
        case "name":
            capturingName = inPlacemark
            nameBuffer = ""
        case "coordinates":
            capturingCoordinates = inLineString || inPoint
            textBuffer = ""
        case "coord":
            capturingCoord = inTrack
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingName { nameBuffer += string }
        if capturingCoordinates || capturingCoord { textBuffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qualifiedName: qName) {
        case "name":
            finishName()
        case "coordinates":
            finishCoordinates()
        case "coord":
            finishCoord()
        case "linestring":
            inLineString = false
        case "point":
            inPoint = false
        case "track":
            inTrack = false
        case "placemark":
            flushPlacemark()
            inPlacemark = false
        case "kml", "document":
            flushPlacemark()
            if routes.isEmpty { flushLoosePoints() }
        default:
            break
        }
    }

    private func finishName() {
        capturingName = false
        let trimmed = nameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { currentName = trimmed }
    }

    private func finishCoordinates() {
        capturingCoordinates = false
        let points = parseCommaTuples(textBuffer)
        if inLineString {
            appendPoints(points, to: &pathPoints)
        } else if inPoint, inPlacemark {
            appendPoints(points, to: &pointPoints)
        } else if inPoint {
            appendPoints(points, to: &loosePoints)
        }
        textBuffer = ""
    }

    private func finishCoord() {
        capturingCoord = false
        if let point = parseSpaceTuple(textBuffer) {
            appendPoints([point], to: &pathPoints)
        }
        textBuffer = ""
    }

    private func flushPlacemark() {
        defer {
            currentName = nil
            pathPoints = []
            pointPoints = []
        }
        if !pathPoints.isEmpty {
            appendRoute(points: pathPoints, name: currentName)
            return
        }
        appendPoints(pointPoints, to: &loosePoints)
    }

    private func flushLoosePoints() {
        appendRoute(points: loosePoints, name: nil)
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

    private func appendPoints(_ incoming: [CoordinatePair], to points: inout [CoordinatePair]) {
        for point in incoming {
            if let last = points.last,
               RoutePlayback.distanceMeters(from: last, to: point) < 0.5 {
                continue
            }
            points.append(point)
        }
    }

    private func parseCommaTuples(_ text: String) -> [CoordinatePair] {
        let normalized = text.replacingOccurrences(of: #",\s*"#, with: ",", options: .regularExpression)
        return normalized
            .split { $0.isWhitespace || $0.isNewline }
            .compactMap { parseLonLat(String($0).split(separator: ",").map(String.init)) }
    }

    private func parseSpaceTuple(_ text: String) -> CoordinatePair? {
        parseLonLat(
            text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        )
    }

    private func parseLonLat(_ parts: [String]) -> CoordinatePair? {
        guard parts.count >= 2,
              let lon = Double(parts[0]),
              let lat = Double(parts[1]),
              lat >= -90, lat <= 90,
              lon >= -180, lon <= 180 else {
            return nil
        }
        return CoordinateConverter.coordinatePair(lat: lat, lon: lon, mapCoordinateSystem: .wgs84)
    }

    private func localName(_ raw: String, qualifiedName: String?) -> String {
        let value = qualifiedName ?? raw
        return value.split(separator: ":").last.map(String.init)?.lowercased() ?? raw.lowercased()
    }
}
