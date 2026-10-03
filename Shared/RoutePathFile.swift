import Foundation
import Darwin

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
        simplify(points, checkpoint: {})
    }

    /// 检查点在调用线程执行；普通保存继续使用不可取消的同步入口。
    static func simplify(_ points: [CoordinatePair], checkpoint: () throws -> Void) rethrows -> [CoordinatePair] {
        try checkpoint()
        guard points.count > maxPoints else { return points }
        var tolerance = 8.0
        var simplified = points
        while simplified.count > maxPoints, tolerance < 5_000 {
            try checkpoint()
            simplified = try douglasPeucker(points, epsilonMeters: tolerance, checkpoint: checkpoint)
            tolerance *= 1.8
        }
        if simplified.count > maxPoints {
            simplified = downsample(points, limit: maxPoints)
        }
        return simplified
    }

    private static func douglasPeucker(_ points: [CoordinatePair], epsilonMeters: Double, checkpoint: () throws -> Void) rethrows -> [CoordinatePair] {
        guard points.count > 2, let origin = points.first else { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        try mark(points, origin: origin, from: 0, to: points.count - 1, epsilonMeters: epsilonMeters, keep: &keep, checkpoint: checkpoint)
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    private static func mark(
        _ points: [CoordinatePair],
        origin: CoordinatePair,
        from: Int,
        to: Int,
        epsilonMeters: Double,
        keep: inout [Bool],
        checkpoint: () throws -> Void
    ) rethrows {
        // 后台线程栈较小，用显式栈保持原先先左后右的深度遍历顺序。
        var pending = [(from, to)]
        while let (from, to) = pending.popLast() {
            try checkpoint()
            guard to - from > 1 else { continue }
            let start = meters(from: origin, to: points[from])
            let end = meters(from: origin, to: points[to])
            var farthest = from
            var farthestDistance = 0.0
            for index in (from + 1)..<to {
                if index.isMultiple(of: 256) { try checkpoint() }
                let distance = segmentDistance(meters(from: origin, to: points[index]), start: start, end: end)
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = index
                }
            }
            guard farthestDistance > epsilonMeters else { continue }
            keep[farthest] = true
            pending.append((farthest, to))
            pending.append((from, farthest))
        }
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
        let x = CoordinateConverter.shortestLongitudeDelta(from: origin.wgs84.longitude, to: point.wgs84.longitude) * lonScale
        return (x, y)
    }

    private static func segmentDistance(
        _ point: (x: Double, y: Double),
        start: (x: Double, y: Double),
        end: (x: Double, y: Double)
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        // 投影必须落在线段上；落在延长线的折返点仍与端点有真实距离。
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
        let clamped = min(1, max(0, projection))
        return hypot(point.x - (start.x + clamped * dx), point.y - (start.y + clamped * dy))
    }
}

final class RoutePathFileStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let beforeWrite: (UUID) throws -> Void
    private let beforeDelete: (UUID) throws -> Void

    init(
        directory: URL,
        beforeDelete: @escaping (UUID) throws -> Void = { _ in },
        beforeWrite: @escaping (UUID) throws -> Void = { _ in }
    ) {
        self.directory = directory
        self.beforeWrite = beforeWrite
        self.beforeDelete = beforeDelete
    }

    static var defaultDirectory: URL {
        AppGroup.containerURL.appendingPathComponent("RoutePaths", isDirectory: true)
    }

    func write(_ route: SavedRoute) throws -> [CoordinatePair]? {
        guard let pathPoints = route.pathPoints, pathPoints.count >= 2 else {
            try delete(route.id)
            return nil
        }
        let simplified = RoutePathSimplifier.simplify(pathPoints)
        let document = RoutePathDocument(
            travelMode: route.travelMode,
            start: point(route.start),
            end: point(route.end),
            vias: route.viaPoints.map(point),
            points: simplified.map(point)
        )
        try beforeWrite(route.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        let staged = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .atomic)
        let verified = try decoder.decode(RoutePathDocument.self, from: Data(contentsOf: staged))
        guard verified == document else { throw CocoaError(.fileReadCorruptFile) }
        // 同目录 rename 原子替换：验证失败或替换失败均保留原路径文件。
        guard Darwin.rename(staged.path, fileURL(route.id).path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return verified.points.map(pair)
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

    func delete(_ id: UUID) throws {
        try beforeDelete(id)
        do {
            try FileManager.default.removeItem(at: fileURL(id))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // 已不存在即满足删除结果；其他错误必须交给决策层。
        }
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
