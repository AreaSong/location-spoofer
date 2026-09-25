import Foundation

struct RoutePathPoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
}

struct RoutePathDocument: Codable, Equatable {
    var travelMode: RouteTravelMode
    var start: RoutePathPoint
    var end: RoutePathPoint
    var vias: [RoutePathPoint]
    var points: [RoutePathPoint]
}

enum RoutePathSimplifier {
    static let maxPoints = 400

    static func simplify(_ points: [CoordinatePair]) -> [CoordinatePair] {
        guard points.count > maxPoints else { return points }
        var tolerance = 8.0
        var simplified = points
        while simplified.count > maxPoints, tolerance < 5_000 {
            simplified = douglasPeucker(points, epsilonMeters: tolerance)
            tolerance *= 1.8
        }
        if simplified.count > maxPoints {
            simplified = downsample(points, limit: maxPoints)
        }
        return simplified
    }

    private static func douglasPeucker(_ points: [CoordinatePair], epsilonMeters: Double) -> [CoordinatePair] {
        guard points.count > 2, let origin = points.first else { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        mark(points, origin: origin, from: 0, to: points.count - 1, epsilonMeters: epsilonMeters, keep: &keep)
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func mark(
        _ points: [CoordinatePair],
        origin: CoordinatePair,
        from: Int,
        to: Int,
        epsilonMeters: Double,
        keep: inout [Bool]
    ) {
        guard to - from > 1 else { return }
        let start = meters(from: origin, to: points[from])
        let end = meters(from: origin, to: points[to])
        var farthest = from
        var farthestDistance = 0.0
        for index in (from + 1)..<to {
            let distance = perpendicularDistance(
                meters(from: origin, to: points[index]),
                start: start,
                end: end
            )
            if distance > farthestDistance {
                farthestDistance = distance
                farthest = index
            }
        }
        guard farthestDistance > epsilonMeters else { return }
        keep[farthest] = true
        mark(points, origin: origin, from: from, to: farthest, epsilonMeters: epsilonMeters, keep: &keep)
        mark(points, origin: origin, from: farthest, to: to, epsilonMeters: epsilonMeters, keep: &keep)
    }

    private static func downsample(_ points: [CoordinatePair], limit: Int) -> [CoordinatePair] {
        guard points.count > limit, limit >= 2 else { return points }
        var chosen: [CoordinatePair] = []
        chosen.reserveCapacity(limit)
        let lastIndex = points.count - 1
        for slot in 0..<limit {
            let index = Int((Double(slot) * Double(lastIndex) / Double(limit - 1)).rounded())
            chosen.append(points[min(index, lastIndex)])
        }
        return chosen
    }

    private static func meters(from origin: CoordinatePair, to point: CoordinatePair) -> (x: Double, y: Double) {
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(origin.wgs84.latitude * .pi / 180)
        let y = (point.wgs84.latitude - origin.wgs84.latitude) * latScale
        let x = (point.wgs84.longitude - origin.wgs84.longitude) * lonScale
        return (x, y)
    }

    private static func perpendicularDistance(
        _ point: (x: Double, y: Double),
        start: (x: Double, y: Double),
        end: (x: Double, y: Double)
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let area = abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x)
        return area / length
    }
}

final class RoutePathFileStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        AppGroup.containerURL.appendingPathComponent("RoutePaths", isDirectory: true)
    }

    func write(_ route: SavedRoute) {
        guard let pathPoints = route.pathPoints, pathPoints.count >= 2 else {
            delete(route.id)
            return
        }
        let simplified = RoutePathSimplifier.simplify(pathPoints)
        let document = RoutePathDocument(
            travelMode: route.travelMode,
            start: point(route.start),
            end: point(route.end),
            vias: route.viaPoints.map(point),
            points: simplified.map(point)
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: fileURL(route.id), options: .atomic)
        } catch {
            RuntimeLogger.error("APP", "路线", "写入路线路径失败", error: error)
        }
    }

    func read(matching route: SavedRoute) -> [CoordinatePair]? {
        guard let data = try? Data(contentsOf: fileURL(route.id)),
              let document = try? decoder.decode(RoutePathDocument.self, from: data),
              document.matches(route),
              document.points.count >= 2,
              document.points.count <= RoutePathSimplifier.maxPoints else {
            return nil
        }
        return document.points.map(pair)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func point(_ pair: CoordinatePair) -> RoutePathPoint {
        RoutePathPoint(latitude: pair.wgs84.latitude, longitude: pair.wgs84.longitude)
    }

    private func pair(_ point: RoutePathPoint) -> CoordinatePair {
        CoordinateConverter.coordinatePair(
            lat: point.latitude,
            lon: point.longitude,
            mapCoordinateSystem: .wgs84
        )
    }
}

private extension RoutePathDocument {
    func matches(_ route: SavedRoute) -> Bool {
        travelMode == route.travelMode
            && start.matches(route.start)
            && end.matches(route.end)
            && vias.count == route.viaPoints.count
            && zip(vias, route.viaPoints).allSatisfy { $0.matches($1) }
    }
}

private extension RoutePathPoint {
    func matches(_ pair: CoordinatePair) -> Bool {
        abs(latitude - pair.wgs84.latitude) < 0.000001
            && abs(longitude - pair.wgs84.longitude) < 0.000001
    }
}
