import Foundation

extension MapSearchModel {
    static func forMap() -> MapSearchModel {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--search-fixtures") {
            return MapSearchModel { query, system in PreviewMapSearchRequest(query: query, system: system) }
        }
        #endif
        return MapSearchModel()
    }
}

#if DEBUG && targetEnvironment(simulator)
/// 原生页面验收专用：显式启动参数下使用合成结果，不发起 MapKit 搜索。
private final class PreviewMapSearchRequest: MapSearchRequest {
    let query: String
    let system: CoordinateConverter.MapCoordinateSystem
    private var continuation: CheckedContinuation<[SearchLocationResult], Error>?

    init(query: String, system: CoordinateConverter.MapCoordinateSystem) {
        self.query = query
        self.system = system
    }

    @MainActor
    func start() async throws -> [SearchLocationResult] {
        if query == "加载" {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        if query == "空结果" { return [] }
        if query == "失败" { throw URLError(.notConnectedToInternet) }
        return (1...6).map { index in
            SearchLocationResult(name: "\(query)·测试地点\(index)",
                                 subtitle: "合成地址 · 中文、emoji 👩🏽‍💻 与较长地点说明，用于检查换行和滚动",
                                 coordinate: .init(latitude: 22 + Double(index) * 0.001, longitude: 113),
                                 mapCoordinateSystem: system)
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
#endif
