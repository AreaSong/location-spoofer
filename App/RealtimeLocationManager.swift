import Combine
import CoreLocation
import Foundation

@MainActor
protocol RealtimeLocationDriving: AnyObject {
    var location: CLLocation? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var delegate: CLLocationManagerDelegate? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

@MainActor
final class CoreLocationDriver: RealtimeLocationDriving {
    private let manager: CLLocationManager

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    var location: CLLocation? { manager.location }
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var delegate: CLLocationManagerDelegate? {
        get { manager.delegate }
        set { manager.delegate = newValue }
    }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }
    func startUpdatingLocation() { manager.startUpdatingLocation() }
    func stopUpdatingLocation() { manager.stopUpdatingLocation() }
}

@MainActor
final class RealtimeLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RealtimeLocationManager(driver: CoreLocationDriver())

    @Published private(set) var location: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isRequesting = false

    private enum RequestPhase: Equatable {
        case awaitingAuthorization
        case oneShot
        case continuousFallback
    }

    private struct ActiveRequest {
        let id: UInt64
        var startedAt: Date?
        let continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>
        var phase: RequestPhase
    }

    private let driver: RealtimeLocationDriving
    private let oneShotTimeoutNanoseconds: UInt64
    private let fallbackTimeoutNanoseconds: UInt64
    static let cacheMaxAge: TimeInterval = 20
    private var nextRequestID: UInt64 = 0
    private var activeRequest: ActiveRequest?
    private var timeoutTask: Task<Void, Never>?

    init(
        driver: RealtimeLocationDriving,
        oneShotTimeoutNanoseconds: UInt64 = 1_500_000_000,
        fallbackTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.driver = driver
        self.oneShotTimeoutNanoseconds = oneShotTimeoutNanoseconds
        self.fallbackTimeoutNanoseconds = fallbackTimeoutNanoseconds
        authorizationStatus = driver.authorizationStatus
        super.init()
        driver.delegate = self
        if let cached = driver.location, Self.isValid(cached) {
            location = cached
        }
    }

    convenience init(driver: RealtimeLocationDriving, timeoutNanoseconds: UInt64) {
        self.init(
            driver: driver,
            oneShotTimeoutNanoseconds: timeoutNanoseconds,
            fallbackTimeoutNanoseconds: timeoutNanoseconds
        )
    }

    func requestLocation() async -> CLLocationCoordinate2D? {
        guard activeRequest == nil else {
            RuntimeLogger.warning("APP", "实时定位", "忽略重复 CLLocationManager 请求", details: [
                "活动requestID": activeRequest.map { String($0.id) } ?? "nil",
                "活动阶段": activeRequest.map { phaseName($0.phase) } ?? "nil"
            ])
            return nil
        }

        authorizationStatus = driver.authorizationStatus
        RuntimeLogger.info("APP", "实时定位", "CLLocationManager 请求入口", details: [
            "授权状态": authorizationName(authorizationStatus),
            "内存缓存存在": String(location != nil),
            "系统缓存存在": String(driver.location != nil)
        ])
        guard authorizationStatus != .denied, authorizationStatus != .restricted else {
            RuntimeLogger.warning("APP", "实时定位", "授权状态不允许定位", details: [
                "授权状态": authorizationName(authorizationStatus)
            ])
            return nil
        }

        if let cached = freshestCachedLocation() {
            location = cached
            RealtimeLocationTrace.log("使用 CLLocationManager 新鲜缓存", location: cached, details: [
                "来源": "manager-memory-or-system",
                "缓存上限秒": String(Int(Self.cacheMaxAge))
            ])
            return cached.coordinate
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        isRequesting = true
        RuntimeLogger.info("APP", "实时定位", "创建 CLLocationManager 请求", details: [
            "requestID": String(requestID),
            "授权状态": authorizationName(authorizationStatus),
            "初始阶段": "awaitingAuthorization"
        ])

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                activeRequest = ActiveRequest(
                    id: requestID,
                    startedAt: nil,
                    continuation: continuation,
                    phase: .awaitingAuthorization
                )

                if authorizationStatus == .notDetermined {
                    RuntimeLogger.info("APP", "实时定位", "请求前台定位授权", details: [
                        "requestID": String(requestID)
                    ])
                    scheduleTimeout(for: requestID, nanoseconds: fallbackTimeoutNanoseconds)
                    driver.requestWhenInUseAuthorization()
                } else {
                    beginOneShot(for: requestID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishRequest(id: requestID, coordinate: nil)
            }
        }
    }

    func startUpdating() {
        if authorizationStatus == .notDetermined {
            driver.requestWhenInUseAuthorization()
        }
        driver.startUpdatingLocation()
    }

    func stopUpdating() {
        driver.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
        authorizationStatus = driver.authorizationStatus
        RuntimeLogger.info("APP", "实时定位", "定位授权状态变化", details: [
            "授权状态": authorizationName(authorizationStatus),
            "requestID": activeRequest.map { String($0.id) } ?? "nil",
            "阶段": activeRequest.map { phaseName($0.phase) } ?? "idle"
        ])
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if let request = activeRequest, request.phase == .awaitingAuthorization {
                beginOneShot(for: request.id)
            }
        case .denied, .restricted:
            finishRequest(id: activeRequest?.id, coordinate: nil)
        case .notDetermined:
            break
        @unknown default:
            finishRequest(id: activeRequest?.id, coordinate: nil)
        }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
        RuntimeLogger.info("APP", "实时定位", "CLLocationManager 返回样本批次", details: [
            "样本数": String(locations.count),
            "requestID": activeRequest.map { String($0.id) } ?? "nil",
            "阶段": activeRequest.map { phaseName($0.phase) } ?? "idle"
        ])
        for (index, candidate) in locations.enumerated() {
            let valid = Self.isValid(candidate)
            let freshEnough = activeRequest?.startedAt.map {
                candidate.timestamp >= $0.addingTimeInterval(-1)
            } ?? false
            RealtimeLocationTrace.log(
                valid ? "检查 CLLocationManager 样本" : "拒绝 CLLocationManager 样本：坐标或精度无效",
                location: candidate,
                details: [
                    "批次索引": String(index),
                    "基础校验通过": String(valid),
                    "满足当前请求时间窗": String(freshEnough)
                ],
                level: valid ? .info : .warning
            )
        }
        let validLocations = locations.filter(Self.isValid)
        if let latestValid = validLocations.last {
            location = latestValid
        }

        guard let request = activeRequest,
              let startedAt = request.startedAt,
              request.phase != .awaitingAuthorization,
              let latest = validLocations.last(where: {
                  $0.timestamp >= startedAt.addingTimeInterval(-1)
              }) else {
            if let request = activeRequest, request.phase != .awaitingAuthorization {
                RuntimeLogger.warning("APP", "实时定位", "本批次没有可完成当前请求的样本", details: [
                    "requestID": String(request.id),
                    "阶段": phaseName(request.phase),
                    "有效样本数": String(validLocations.count)
                ])
            }
            return
        }
        RealtimeLocationTrace.log("接受 CLLocationManager 样本并完成请求", location: latest, details: [
            "requestID": String(request.id),
            "阶段": phaseName(request.phase)
        ])
        finishRequest(id: request.id, coordinate: latest.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
        guard let request = activeRequest else { return }
        RuntimeLogger.warning("APP", "定位", "定位回调失败", details: [
            "requestID": String(request.id),
            "error": error.localizedDescription
        ])

        let nsError = error as NSError
        let isAuthorizationDenied = nsError.domain == kCLErrorDomain
            && nsError.code == CLError.denied.rawValue

        if request.phase == .oneShot,
           !isAuthorizationDenied,
           authorizationStatus != .denied,
           authorizationStatus != .restricted {
            beginFallback(for: request.id)
        } else {
            finishRequest(id: request.id, coordinate: nil)
        }
        }
    }

    func isFreshEnoughForRealtimeRequest(_ location: CLLocation, now: Date = Date()) -> Bool {
        Self.isValid(location)
            && abs(location.timestamp.timeIntervalSince(now)) <= Self.cacheMaxAge
    }

    private func freshestCachedLocation(now: Date = Date()) -> CLLocation? {
        let candidates = [location, driver.location].compactMap { $0 }
        for candidate in candidates where !isFreshEnoughForRealtimeRequest(candidate, now: now) {
            let valid = Self.isValid(candidate)
            let age = abs(candidate.timestamp.timeIntervalSince(now))
            RealtimeLocationTrace.log("跳过 CLLocationManager 缓存样本", location: candidate, details: [
                "基础校验通过": String(valid),
                "缓存时效通过": String(age <= Self.cacheMaxAge),
                "缓存上限秒": String(Int(Self.cacheMaxAge))
            ], level: .warning)
        }
        return candidates
            .filter { isFreshEnoughForRealtimeRequest($0, now: now) }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    private static func isValid(_ location: CLLocation) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy >= 0
    }

    private func scheduleTimeout(for requestID: UInt64, nanoseconds: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.handleTimeout(for: requestID)
        }
    }

    private func handleTimeout(for requestID: UInt64) {
        guard let request = activeRequest, request.id == requestID else { return }
        switch request.phase {
        case .awaitingAuthorization:
            RuntimeLogger.warning("APP", "定位", "等待定位授权超时", details: ["requestID": String(requestID)])
            finishRequest(id: requestID, coordinate: nil)
        case .oneShot:
            RuntimeLogger.warning("APP", "定位", "单次定位超时，切换持续定位", details: ["requestID": String(requestID)])
            beginFallback(for: requestID)
        case .continuousFallback:
            RuntimeLogger.warning("APP", "定位", "持续定位超时", details: ["requestID": String(requestID)])
            finishRequest(id: requestID, coordinate: nil)
        }
    }

    private func beginOneShot(for requestID: UInt64) {
        guard var request = activeRequest,
              request.id == requestID,
              request.phase == .awaitingAuthorization else { return }
        request.phase = .oneShot
        request.startedAt = Date()
        activeRequest = request
        RuntimeLogger.info("APP", "实时定位", "开始 CLLocationManager 单次定位", details: [
            "requestID": String(requestID),
            "超时毫秒": String(oneShotTimeoutNanoseconds / 1_000_000)
        ])
        scheduleTimeout(for: requestID, nanoseconds: oneShotTimeoutNanoseconds)
        driver.requestLocation()
    }

    private func beginFallback(for requestID: UInt64) {
        guard var request = activeRequest,
              request.id == requestID,
              request.phase == .oneShot else { return }
        request.phase = .continuousFallback
        activeRequest = request
        RuntimeLogger.info("APP", "实时定位", "开始 CLLocationManager 持续定位兜底", details: [
            "requestID": String(requestID),
            "超时毫秒": String(fallbackTimeoutNanoseconds / 1_000_000)
        ])
        driver.startUpdatingLocation()
        scheduleTimeout(for: requestID, nanoseconds: fallbackTimeoutNanoseconds)
    }

    private func finishRequest(id requestID: UInt64?, coordinate: CLLocationCoordinate2D?) {
        guard let requestID,
              let request = activeRequest,
              request.id == requestID else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        if request.phase == .continuousFallback {
            driver.stopUpdatingLocation()
        }
        activeRequest = nil
        isRequesting = false

        if coordinate != nil {
            RuntimeLogger.info("APP", "实时定位", "CLLocationManager 请求完成", details: [
                "requestID": String(requestID),
                "最终阶段": phaseName(request.phase),
                "有坐标": "true"
            ])
        } else {
            RuntimeLogger.warning("APP", "实时定位", "CLLocationManager 请求结束但没有坐标", details: [
                "requestID": String(requestID),
                "最终阶段": phaseName(request.phase),
                "有坐标": "false"
            ])
        }
        request.continuation.resume(returning: coordinate)
    }

    private func phaseName(_ phase: RequestPhase) -> String {
        switch phase {
        case .awaitingAuthorization: return "awaitingAuthorization"
        case .oneShot: return "oneShot"
        case .continuousFallback: return "continuousFallback"
        }
    }

    private func authorizationName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
