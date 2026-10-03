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

    static func decode(
        _ data: Data, fallbackName: String = "导入路线",
        checkpoint: @escaping (RouteImportPreparation.Stage) throws -> Void = { _ in try Task.checkCancellation() }
    ) throws -> [SavedRoute] {
        try checkpoint(.decoding)
        if looksLikeKMZ(data) { throw ParseError.unsupportedArchive }
        let collector = Collector(fallbackName: fallbackName, checkpoint: checkpoint)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        let parsed = parser.parse()
        if let error = collector.failure { throw error }
        try checkpoint(.parsing)
        guard parsed else { throw ParseError.invalidXML }
        let routes = collector.routes
        guard !routes.isEmpty else { throw ParseError.empty }
        return routes
    }
}

private final class Collector: NSObject, XMLParserDelegate {
    private let checkpoint: (RouteImportPreparation.Stage) throws -> Void
    private(set) var failure: Error?
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

    init(fallbackName: String, checkpoint: @escaping (RouteImportPreparation.Stage) throws -> Void) {
        self.fallbackName = fallbackName
        self.checkpoint = checkpoint
    }

    /// 只在 XMLParser 自己的同步回调中终止解析，不跨线程操作解析器。
    private func collect(_ parser: XMLParser, body: () throws -> Void) {
        guard failure == nil else { return }
        do {
            try checkpoint(.parsing)
            try body()
        } catch {
            failure = error
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        collect(parser) {
            switch localName(elementName, qualifiedName: qName) {
            case "placemark":
                try flushPlacemark()
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
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        collect(parser) {
            if capturingName { nameBuffer += string }
            if capturingCoordinates || capturingCoord { textBuffer += string }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        collect(parser) {
            switch localName(elementName, qualifiedName: qName) {
            case "name":
                finishName()
            case "coordinates":
                try finishCoordinates()
            case "coord":
                try finishCoord()
            case "linestring":
                inLineString = false
            case "point":
                inPoint = false
            case "track":
                inTrack = false
            case "placemark":
                try flushPlacemark()
                inPlacemark = false
            case "kml", "document":
                try flushPlacemark()
                if routes.isEmpty { try flushLoosePoints() }
            default:
                break
            }
        }
    }

    private func finishName() {
        capturingName = false
        let trimmed = nameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { currentName = trimmed }
    }

    private func finishCoordinates() throws {
        capturingCoordinates = false
        let points = try parseCommaTuples(textBuffer)
        if inLineString {
            try appendPoints(points, to: &pathPoints)
        } else if inPoint, inPlacemark {
            try appendPoints(points, to: &pointPoints)
        } else if inPoint {
            try appendPoints(points, to: &loosePoints)
        }
        textBuffer = ""
    }

    private func finishCoord() throws {
        capturingCoord = false
        if let point = try parseSpaceTuple(textBuffer) {
            try appendPoints([point], to: &pathPoints)
        }
        textBuffer = ""
    }

    private func flushPlacemark() throws {
        defer {
            currentName = nil
            pathPoints = []
            pointPoints = []
        }
        if !pathPoints.isEmpty {
            try appendRoute(points: pathPoints, name: currentName)
            return
        }
        try appendPoints(pointPoints, to: &loosePoints)
    }

    private func flushLoosePoints() throws {
        try appendRoute(points: loosePoints, name: nil)
    }

    private func appendRoute(points: [CoordinatePair], name: String?) throws {
        try checkpoint(.simplifying(points.count))
        let simplified = try RoutePathSimplifier.simplify(points) { try checkpoint(.simplificationStep) }
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

    private func appendPoints(_ incoming: [CoordinatePair], to points: inout [CoordinatePair]) throws {
        for point in incoming {
            try checkpoint(.converting)
            if let last = points.last,
               RoutePlayback.distanceMeters(from: last, to: point) < 0.5 {
                continue
            }
            points.append(point)
        }
    }

    private func parseCommaTuples(_ text: String) throws -> [CoordinatePair] {
        let normalized = text.replacingOccurrences(of: #",\s*"#, with: ",", options: .regularExpression)
        return try normalized
            .split { $0.isWhitespace || $0.isNewline }
            .compactMap { try parseLonLat(String($0).split(separator: ",").map(String.init)) }
    }

    private func parseSpaceTuple(_ text: String) throws -> CoordinatePair? {
        try parseLonLat(
            text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        )
    }

    private func parseLonLat(_ parts: [String]) throws -> CoordinatePair? {
        try checkpoint(.converting)
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
