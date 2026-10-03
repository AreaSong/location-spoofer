import XCTest
@testable import PaopaoLocationSpoofer

enum RouteImportSamples {
    static func route(_ index: Int = 0, count: Int = 2, name: String = "合成路线") -> SavedRoute {
        let points = (0..<count).map { i in
            CoordinateConverter.coordinatePair(lat: 20 + Double(index) * 0.1 + Double(i) * 0.00001,
                lon: 113 + sin(Double(i) / 40) * 0.01, mapCoordinateSystem: .wgs84)
        }
        return SavedRoute(name: name, start: points.first!, end: points.last!, travelMode: .walk,
            speedKilometersPerHour: 5, offsetMeters: 3, repeatMode: .roundTrip,
            pathPoints: points, createdAt: Date(timeIntervalSince1970: 100))
    }

    // 直接生成外部 JSON，不经会主动简化的导出入口。
    static func json(_ routes: [SavedRoute]) throws -> String {
        let coordinates: (CoordinatePair) -> FavoriteTransfer.Coordinate = {
            .init(latitude: $0.wgs84.latitude, longitude: $0.wgs84.longitude)
        }
        let items = routes.map { route in
            RouteTransfer.Item(id: route.id, name: route.name, travelMode: route.travelMode.rawValue,
                speedKilometersPerHour: route.speedKilometersPerHour, offsetMeters: route.offsetMeters,
                repeatMode: route.repeatMode.rawValue, createdAt: "1970-01-01T00:01:40.000Z",
                start: coordinates(route.start), end: coordinates(route.end),
                vias: route.viaPoints.map(coordinates), path: route.pathPoints?.map(coordinates))
        }
        return String(decoding: try JSONEncoder().encode(RouteTransfer.Document(
            format: RouteTransfer.format, version: 1, routes: items)), as: UTF8.self)
    }

    static func xml(_ format: String, count: Int = 1000) -> String {
        let points = route(count: count).pathPoints!
        if format == "gpx" {
            return "<gpx><trk><name>合成路线</name><trkseg>" + points.map {
                "<trkpt lat=\"\($0.wgs84.latitude)\" lon=\"\($0.wgs84.longitude)\"/>"
            }.joined() + "</trkseg></trk></gpx>"
        }
        return "<kml><Placemark><name>合成路线</name><LineString><coordinates>" + points.map {
            "\($0.wgs84.longitude),\($0.wgs84.latitude)"
        }.joined(separator: " ") + "</coordinates></LineString></Placemark></kml>"
    }
}

/// 仅用于测试后台不可中断点。用到达通知和显式释放驱动，不用 sleep。
final class RouteImportGate {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?

    func pauseOnce() {
        condition.lock()
        defer { condition.unlock() }
        guard !entered else { return }
        entered = true
        observer?.resume(); observer = nil
        while !released { condition.wait() }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered { continuation.resume() } else { observer = continuation }
            condition.unlock()
        }
    }

    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@MainActor
class RouteImportTestCase: XCTestCase {
    func isolatedStore(beforeWrite: @escaping (UUID) throws -> Void = { _ in }) -> (SavedRouteStore, UserDefaults, URL) {
        let suite = "RouteImportTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (SavedRouteStore(defaults: defaults, pathDirectory: directory, beforePathWrite: beforeWrite), defaults, directory)
    }

    func run(_ text: String, coordinator: RouteImportCoordinator, page: UUID, store: SavedRouteStore) async {
        XCTAssertTrue(coordinator.start(.clipboard(text), pageID: page, isPageActive: { true }) {
            store.importTransferred($0.routes)
        })
        await coordinator.waitForCompletion()
    }
}
