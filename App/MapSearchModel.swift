import Combine
import MapKit

struct SearchLocationResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let mapCoordinateSystem: CoordinateConverter.MapCoordinateSystem
    var remembersPreference = false
}

protocol MapSearchRequest: AnyObject {
    @MainActor func start() async throws -> [SearchLocationResult]
    func cancel()
}

final class LocalMapSearchRequest: MapSearchRequest {
    private let search: MKLocalSearch
    private let system: CoordinateConverter.MapCoordinateSystem

    init(query: String, system: CoordinateConverter.MapCoordinateSystem) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        search = MKLocalSearch(request: request)
        self.system = system
    }

    @MainActor
    func start() async throws -> [SearchLocationResult] {
        let response = try await search.start()
        return response.mapItems.prefix(6).map { item in
            SearchLocationResult(
                name: item.name ?? "未命名",
                subtitle: [item.placemark.locality, item.placemark.subLocality, item.placemark.thoroughfare]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                coordinate: item.placemark.coordinate,
                mapCoordinateSystem: system
            )
        }
    }

    func cancel() { search.cancel() }
}

@MainActor
final class MapSearchModel: ObservableObject {
    @Published var text = "" {
        didSet {
            // 不重写输入或焦点：包括输入法组合输入在内，编辑只终结旧查询意图。
            if text != oldValue { dismissResults() }
        }
    }
    @Published private(set) var results: [SearchLocationResult] = []
    @Published private(set) var error = ""
    @Published private(set) var isSearching = false
    private(set) var submittedQuery: String?
    private var generation: UInt64 = 0
    private var request: MapSearchRequest?
    private var task: Task<Void, Never>?
    private let makeRequest: (String, CoordinateConverter.MapCoordinateSystem) -> MapSearchRequest

    init(makeRequest: @escaping (String, CoordinateConverter.MapCoordinateSystem) -> MapSearchRequest = {
        LocalMapSearchRequest(query: $0, system: $1)
    }) {
        self.makeRequest = makeRequest
    }

    deinit {
        task?.cancel()
        request?.cancel()
    }

    @discardableResult
    func submit(
        system: CoordinateConverter.MapCoordinateSystem,
        preferred: CoordinateConverter.MapCoordinateSystem
    ) -> Task<Void, Never>? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        dismissResults()
        guard !query.isEmpty else { return nil }
        let token = generation
        submittedQuery = query
        if presentParsedInput(query, preferred: preferred) { return nil }
        isSearching = true
        error = ""
        let request = makeRequest(query, system)
        self.request = request
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let found = try await request.start()
                guard !Task.isCancelled else { return }
                self?.finish(.success(found), token: token, query: query)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(.failure(error), token: token, query: query)
            }
        }
        self.task = task
        return task
    }

    func clear() {
        dismissResults()
        text = ""
    }

    func dismissResults() {
        // 先撤销发布资格，再取消系统请求；取消回调也可能立即返回。
        generation &+= 1
        task?.cancel()
        request?.cancel()
        task = nil
        request = nil
        isSearching = false
        submittedQuery = nil
        results = []
        error = ""
    }

    func select(_ result: SearchLocationResult) {
        text = result.name
        dismissResults()
    }

    func remove(_ result: SearchLocationResult) {
        results.removeAll { $0.id == result.id }
    }

    private func finish(_ outcome: Result<[SearchLocationResult], Error>, token: UInt64, query: String) {
        guard token == generation, submittedQuery == query,
              text.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        task = nil
        request = nil
        isSearching = false
        switch outcome {
        case .success(let found):
            results = Array(found.prefix(6))
            error = results.isEmpty ? "没有找到相关地点" : ""
        case .failure(let failure):
            results = []
            error = failure is CancellationError ? "" : failure.localizedDescription
        }
    }

    private func presentParsedInput(
        _ query: String,
        preferred: CoordinateConverter.MapCoordinateSystem
    ) -> Bool {
        if let link = MapLinkParser.parse(query) {
            presentCoordinateChoices(
                name: link.name ?? String(format: "%.6f, %.6f", link.latitude, link.longitude),
                coordinate: CLLocationCoordinate2D(latitude: link.latitude, longitude: link.longitude),
                preferred: link.inferredSystem,
                sourceLabel: "\(link.sourceName)链接",
                remembersPreference: false
            )
            return true
        }
        guard let coordinate = CoordinateTextParser.parse(query) else { return false }
        presentCoordinateChoices(
            name: String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude),
            coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
            preferred: preferred,
            sourceLabel: nil,
            remembersPreference: true
        )
        return true
    }

    private func presentCoordinateChoices(
        name: String,
        coordinate: CLLocationCoordinate2D,
        preferred: CoordinateConverter.MapCoordinateSystem,
        sourceLabel: String?,
        remembersPreference: Bool
    ) {
        isSearching = false
        error = ""
        func result(_ system: CoordinateConverter.MapCoordinateSystem) -> SearchLocationResult {
            let choice = system == .gcj02 ? "按国内标准(GCJ-02)选点" : "按国际标准(WGS-84)选点"
            return SearchLocationResult(
                name: name,
                subtitle: sourceLabel.map { "\($0) · \(choice)" } ?? choice,
                coordinate: coordinate,
                mapCoordinateSystem: system,
                remembersPreference: remembersPreference
            )
        }
        results = preferred == .wgs84 ? [result(.wgs84), result(.gcj02)] : [result(.gcj02), result(.wgs84)]
    }
}
