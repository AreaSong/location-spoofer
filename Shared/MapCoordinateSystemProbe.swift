import Foundation
import CoreLocation
import MapKit

extension CoordinateConverter {
    private static var gcj02FixedAnchorNames: Set<String> {
        ["林士街", "rumsey street", "rumsey st", "rumsey st."]
    }

    private static var wgs84FixedAnchorNames: Set<String> {
        ["connaught road west"]
    }

    /// Startup gate: only request realtime location if the public MapKit probe
    /// cannot resolve a coordinate type. This guarantees a finite answer before
    /// persisted map positions are replayed.
    @MainActor
    static func resolveInitialMapCoordinateSystem() async -> MapCoordinateSystem {
        guard !mapCoordinateSystemCheckPending else {
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准检测已有请求进行中")
            return currentMapCoordinateSystem
        }
        mapCoordinateSystemCheckPending = true
        defer { mapCoordinateSystemCheckPending = false }
        RuntimeLogger.info("APP", "坐标转换", "地图坐标标准检测开始", details: [
            "锚点": "22.283819,114.158439",
            "判定规则": "白名单命中才改判，未知名称走兜底",
            "缓存": "false"
        ])

        switch await fixedAnchorCoordinateSystemProbe() {
        case let .response(name, count):
            if let detected = mapCoordinateSystem(forFixedAnchorFirstResultName: name) {
                return commitInitialMapCoordinateSystem(
                    detected,
                    usedFallback: false,
                    details: [
                        "首条名称": name,
                        "结果数": String(count),
                        "命中白名单": detected.rawValue,
                        "最终标准": detected.rawValue,
                        "结果来源": "固定锚点"
                    ]
                )
            }
            return await fallbackInitialMapCoordinateSystem(
                reason: "固定锚点名称未列入白名单: \(name)",
                firstResultName: name,
                resultCount: count
            )
        case .unavailable(let reason), .timedOut(let reason):
            return await fallbackInitialMapCoordinateSystem(reason: reason)
        case .cancelled:
            initialMapCoordinateSystemUsedFallback = true
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准检测被取消，保留默认国内标准", details: [
                "最终标准": currentMapCoordinateSystem.rawValue
            ])
            return currentMapCoordinateSystem
        }
    }

    /// Re-runs the fixed-anchor MapKit behavior probe while the map is alive.
    /// Runtime failures preserve the last confirmed type: a potentially spoofed
    /// Core Location sample is not authoritative for MapKit's representation.
    @MainActor
    static func refreshRuntimeMapCoordinateSystem(reason: String) async -> RuntimeMapCoordinateSystemRefreshResult {
        guard !mapCoordinateSystemCheckPending else {
            RuntimeLogger.info("APP", "坐标转换", "地图坐标标准运行期检测合并到进行中请求", details: [
                "触发原因": reason,
                "当前标准": currentMapCoordinateSystem.rawValue
            ])
            return .unchanged(currentMapCoordinateSystem)
        }
        mapCoordinateSystemCheckPending = true
        defer { mapCoordinateSystemCheckPending = false }

        let previous = currentMapCoordinateSystem
        RuntimeLogger.info("APP", "坐标转换", "地图坐标标准运行期检测开始", details: [
            "触发原因": reason,
            "检测前标准": previous.rawValue,
            "锚点": "22.283819,114.158439",
            "缓存": "false"
        ])

        switch await fixedAnchorCoordinateSystemProbe() {
        case let .response(name, count):
            guard !Task.isCancelled else {
                RuntimeLogger.info("APP", "坐标转换", "地图坐标标准运行期检测结果已过期，取消写入", details: [
                    "触发原因": reason,
                    "保留标准": previous.rawValue
                ])
                return .cancelled
            }
            return applyRuntimeRefreshOutcome(
                runtimeRefreshResult(previous: previous, firstResultName: name),
                reason: reason,
                firstResultName: name,
                resultCount: count,
                previous: previous
            )
        case .unavailable(let failureReason), .timedOut(let failureReason):
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准运行期检测失败，保留当前标准", details: [
                "触发原因": reason,
                "原因": failureReason,
                "保留标准": previous.rawValue
            ])
            return .unavailable(reason: failureReason)
        case .cancelled:
            RuntimeLogger.info("APP", "坐标转换", "地图坐标标准运行期检测已取消", details: [
                "触发原因": reason,
                "保留标准": previous.rawValue
            ])
            return .cancelled
        }
    }

    /// 固定锚点首条名称必须命中白名单才改判。未知名称返回 nil，避免误判成 WGS-84。
    static func mapCoordinateSystem(forFixedAnchorFirstResultName name: String) -> MapCoordinateSystem? {
        let normalized = normalizedFixedAnchorResultName(name)
        guard !normalized.isEmpty else { return nil }
        if matchesFixedAnchorName(normalized, allowed: gcj02FixedAnchorNames) {
            return .gcj02
        }
        if matchesFixedAnchorName(normalized, allowed: wgs84FixedAnchorNames) {
            return .wgs84
        }
        return nil
    }

    static func runtimeRefreshResult(
        previous: MapCoordinateSystem,
        firstResultName: String
    ) -> RuntimeMapCoordinateSystemRefreshResult {
        guard let detected = mapCoordinateSystem(forFixedAnchorFirstResultName: firstResultName) else {
            return .unavailable(reason: "固定锚点名称未列入白名单")
        }
        if detected == previous {
            return .unchanged(detected)
        }
        return .changed(MapCoordinateSystemChange(previous: previous, current: detected))
    }

    /// A user-requested realtime sample is WGS-84 and can correct a provisional
    /// startup map coordinate system without altering persisted coordinate pairs.
    @MainActor
    static func correctMapCoordinateSystemUsingRealtime(_ coordinate: CLLocationCoordinate2D) -> MapCoordinateSystemChange? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        guard initialMapCoordinateSystemUsedFallback else {
            RuntimeLogger.info("APP", "坐标转换", "实时定位不覆盖固定锚点的明确检测结果", details: [
                "当前标准": currentMapCoordinateSystem.rawValue
            ])
            return nil
        }
        let next: MapCoordinateSystem = usesGCJ02ServiceArea(lat: coordinate.latitude, lon: coordinate.longitude) ? .gcj02 : .wgs84
        guard next != currentMapCoordinateSystem else {
            RuntimeLogger.info("APP", "坐标转换", "实时定位确认兜底地图坐标标准无需修正", details: [
                "当前标准": currentMapCoordinateSystem.rawValue
            ])
            return nil
        }
        let change = MapCoordinateSystemChange(previous: currentMapCoordinateSystem, current: next)
        currentMapCoordinateSystem = next
        RuntimeLogger.warning("APP", "坐标转换", "实时定位修正启动兜底地图坐标标准", details: [
            "from": change.previous.rawValue,
            "to": change.current.rawValue
        ])
        return change
    }

    private static func normalizedFixedAnchorResultName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0.isWhitespace }
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func matchesFixedAnchorName(_ name: String, allowed: Set<String>) -> Bool {
        if allowed.contains(name) { return true }
        for allowedName in allowed {
            if name.hasPrefix(allowedName + " ")
                || name.hasPrefix(allowedName + ",")
                || name.hasPrefix(allowedName + "，") {
                return true
            }
        }
        return false
    }

    @MainActor
    private static func commitInitialMapCoordinateSystem(
        _ nextType: MapCoordinateSystem,
        usedFallback: Bool,
        details: [String: String]
    ) -> MapCoordinateSystem {
        currentMapCoordinateSystem = nextType
        initialMapCoordinateSystemUsedFallback = usedFallback
        RuntimeLogger.info(
            "APP",
            "坐标转换",
            usedFallback ? "地图坐标标准检测使用兜底结果" : "地图坐标标准检测获得明确结果",
            details: details
        )
        RuntimeLogger.info("APP", "坐标转换", "地图坐标标准已确定，允许创建地图", details: [
            "最终标准": nextType.rawValue,
            "使用兜底": String(usedFallback),
            "缓存": "false"
        ])
        return nextType
    }

    @MainActor
    private static func fallbackInitialMapCoordinateSystem(
        reason: String,
        firstResultName: String? = nil,
        resultCount: Int? = nil
    ) async -> MapCoordinateSystem {
        var details = ["原因": reason]
        if let firstResultName { details["首条名称"] = firstResultName }
        if let resultCount { details["结果数"] = String(resultCount) }
        RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准检测不可用，开始实时定位兜底", details: details)
        let realtime = await RealtimeLocationManager.shared.requestLocation()
        let nextType: MapCoordinateSystem
        if let realtime,
           CLLocationCoordinate2DIsValid(realtime),
           !usesGCJ02ServiceArea(lat: realtime.latitude, lon: realtime.longitude) {
            nextType = .wgs84
        } else {
            nextType = .gcj02
        }
        return commitInitialMapCoordinateSystem(
            nextType,
            usedFallback: true,
            details: [
                "探测失败原因": reason,
                "实时定位存在": String(realtime != nil),
                "最终标准": nextType.rawValue,
                "结果来源": realtime == nil ? "默认国内标准" : "实时定位服务区域"
            ]
        )
    }

    @MainActor
    private static func applyRuntimeRefreshOutcome(
        _ outcome: RuntimeMapCoordinateSystemRefreshResult,
        reason: String,
        firstResultName: String,
        resultCount: Int,
        previous: MapCoordinateSystem
    ) -> RuntimeMapCoordinateSystemRefreshResult {
        switch outcome {
        case .unchanged(let detected):
            initialMapCoordinateSystemUsedFallback = false
            RuntimeLogger.info("APP", "坐标转换", "地图坐标标准运行期检测完成，标准未变化", details: [
                "触发原因": reason,
                "首条名称": firstResultName,
                "结果数": String(resultCount),
                "确认标准": detected.rawValue
            ])
            return outcome
        case .changed(let change):
            initialMapCoordinateSystemUsedFallback = false
            currentMapCoordinateSystem = change.current
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准运行期检测发现切换", details: [
                "触发原因": reason,
                "首条名称": firstResultName,
                "结果数": String(resultCount),
                "from": previous.rawValue,
                "to": change.current.rawValue
            ])
            return outcome
        case .unavailable(let failureReason):
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准运行期检测失败，保留当前标准", details: [
                "触发原因": reason,
                "原因": failureReason,
                "首条名称": firstResultName,
                "结果数": String(resultCount),
                "保留标准": previous.rawValue
            ])
            return outcome
        case .cancelled:
            return outcome
        }
    }

    private static func fixedAnchorCoordinateSystemProbe() async -> MapCoordinateSystemProbeResult {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "22.283819, 114.158439"
        let search = MKLocalSearch(request: request)
        let resolver = MapCoordinateSystemProbeResolver()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let timeout = DispatchWorkItem {
                    search.cancel()
                    resolver.resolve(.timedOut(reason: "固定锚点查询超过5秒"))
                }
                resolver.install(continuation, timeout: timeout)
                guard !resolver.isResolved else { return }
                search.start { response, error in
                    if let error {
                        let nsError = error as NSError
                        resolver.resolve(.unavailable(
                            reason: "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
                        ))
                        return
                    }
                    let items = response?.mapItems ?? []
                    guard let first = items.first,
                          let name = first.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else {
                        resolver.resolve(.unavailable(reason: "固定锚点查询返回空结果"))
                        return
                    }
                    resolver.resolve(.response(name: name, count: items.count))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            }
        }, onCancel: {
            search.cancel()
            resolver.resolve(.cancelled)
        })
    }
}

private enum MapCoordinateSystemProbeResult {
    case response(name: String, count: Int)
    case unavailable(reason: String)
    case timedOut(reason: String)
    case cancelled
}

private final class MapCoordinateSystemProbeResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var result: MapCoordinateSystemProbeResult?
    private var continuation: CheckedContinuation<MapCoordinateSystemProbeResult, Never>?
    private var timeout: DispatchWorkItem?

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func install(
        _ continuation: CheckedContinuation<MapCoordinateSystemProbeResult, Never>,
        timeout: DispatchWorkItem
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            timeout.cancel()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        self.timeout = timeout
        lock.unlock()
    }

    func resolve(_ nextResult: MapCoordinateSystemProbeResult) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = nextResult
        let continuation = continuation
        let timeout = timeout
        self.continuation = nil
        self.timeout = nil
        lock.unlock()

        timeout?.cancel()
        continuation?.resume(returning: nextResult)
    }
}
