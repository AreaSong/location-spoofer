import Foundation

enum SpoofSessionEffect: Equatable {
    case activationSucceeded
    case deactivationSucceeded
        case offerCommunityContribution
        case localVerificationFailed(VerificationResult)
        case developerPushFailed(String)
        case resetLocalDiagnosis
}

/// 虚拟定位的开启、停止和路线写入。
/// 操作序号作废旧任务；第三方写入一旦成功，就不因地图又移动而回滚。
@MainActor
final class SpoofSession: ObservableObject {
    struct Services {
        var mode: () -> ProxyRuntimeMode
        var isUseBlocked: () -> Bool
        var selectionRevision: () -> UInt64
        var localSpoofEnabled: () -> Bool
        var thirdPartyClientName: () -> String
        var routeIsPlaying: () -> Bool
        var routeWaitsForActivation: () -> Bool
        var routeOffsetMeters: () -> Double
        var accuracyMeters: () -> Int
        var pauseRoute: () -> Void
        var verify: () async -> VerificationResult
        var applyVerified: (FavoriteLocation) -> Bool
        var updateLocalWGS84: (Double, Double, Int) -> Bool
        var clearLocal: () -> Void
        var saveThirdParty: (FavoriteLocation, Double?) async throws -> ThirdPartyProxySettingsResponse
        var clearThirdParty: () async throws -> Void
        var queryThirdParty: () async throws -> ThirdPartyProxySettingsResponse
        var clearThirdPartyFailure: () -> Void
        var recordThirdPartyFailure: (Error) -> Void
        var recordThirdPartyMessage: (String) -> Void
        var pushDeveloper: (FavoriteLocation) async -> RouteLocationPushFailure?
        var clearDeveloper: () async -> Void
    }

    @Published private(set) var state: SpoofState
    /// 已经写入代理或第三方客户端的坐标，不跟随路线播放的插值。
    @Published private(set) var writtenLatitude: Double?
    @Published private(set) var writtenLongitude: Double?
    @Published private(set) var effectRevision: UInt64 = 0

    private var services: Services?
    private var operationID: UInt64 = 0
    private var operationTask: Task<Void, Never>?
    private var pendingEffects: [SpoofSessionEffect] = []

    init(
        state: SpoofState = .idle,
        writtenLatitude: Double? = nil,
        writtenLongitude: Double? = nil
    ) {
        self.state = state
        self.writtenLatitude = writtenLatitude
        self.writtenLongitude = writtenLongitude
    }

    func bind(_ services: Services) {
        self.services = services
    }

    func consumeEffects() -> [SpoofSessionEffect] {
        let effects = pendingEffects
        pendingEffects.removeAll()
        return effects
    }

    func setPreviewActive(_ active: Bool, latitude: Double?, longitude: Double?) {
        operationTask?.cancel()
        operationTask = nil
        state = active ? .active : .idle
        writtenLatitude = active ? latitude : nil
        writtenLongitude = active ? longitude : nil
        effectRevision &+= 1
    }

    func begin(target: FavoriteLocation) {
        guard let services else { return }
        if services.isUseBlocked() { return }
        if services.routeIsPlaying() { services.pauseRoute() }
        guard state != .verifying, operationTask == nil else { return }
        let wasActive = state == .active
        operationID &+= 1
        let operationID = operationID
        let selectionRevision = services.selectionRevision()
        state = .verifying
        switch services.mode() {
        case .thirdParty:
            operationTask = Task {
                await self.saveThirdParty(
                    target,
                    operationID: operationID,
                    wasActive: wasActive,
                    selectionRevision: selectionRevision
                )
            }
        case .developerTunnel:
            operationTask = Task {
                await self.pushDeveloperLocation(target, operationID: operationID, wasActive: wasActive)
            }
        case .localWiFi:
            operationTask = Task {
                await self.verifyLocal(target, operationID: operationID, selectionRevision: selectionRevision)
            }
        }
    }

    func stop() {
        guard let services else { return }
        services.pauseRoute()
        invalidateOperation()
        switch services.mode() {
        case .thirdParty:
            state = .verifying
            let operationID = self.operationID
            operationTask = Task { await self.clearThirdParty(operationID: operationID) }
            return
        case .developerTunnel:
            state = .verifying
            let operationID = self.operationID
            operationTask = Task { await self.clearDeveloperLocation(operationID: operationID) }
            return
        case .localWiFi:
            break
        }
        services.clearLocal()
        writtenLatitude = nil
        writtenLongitude = nil
        state = .idle
        enqueue(.resetLocalDiagnosis, .deactivationSucceeded)
    }

    func writeRoute(_ pair: CoordinatePair, offsetMeters: Double) async -> Bool {
        guard let services, !services.isUseBlocked() else { return false }
        if services.mode() == .thirdParty {
            return await writeThirdPartyRoute(pair, offsetMeters: offsetMeters, services: services)
        }
        return writeLocalRoute(pair, offsetMeters: offsetMeters, services: services)
    }

    func refreshThirdParty() {
        guard let services, services.mode() == .thirdParty, operationTask == nil else { return }
        operationID &+= 1
        let operationID = operationID
        operationTask = Task { await self.queryThirdParty(operationID: operationID) }
    }

    func cancelForModeChange() {
        guard let services else { return }
        invalidateOperation()
        writtenLatitude = nil
        writtenLongitude = nil
        if services.mode() == .localWiFi {
            state = services.localSpoofEnabled() ? .active : .idle
        } else {
            state = .idle
        }
    }

    func noteLocalProxyStopped() {
        guard let services, services.mode() == .localWiFi, state == .active else { return }
        services.clearLocal()
        state = .idle
    }

    private func pushDeveloperLocation(
        _ target: FavoriteLocation,
        operationID: UInt64,
        wasActive: Bool
    ) async {
        guard let services else { return }
        let failure = await services.pushDeveloper(target)
        guard accept(operationID), services.mode() == .developerTunnel else { return }
        if let failure {
            state = wasActive ? .active : .idle
            enqueue(.developerPushFailed(failure.message))
        } else {
            state = .active
            writtenLatitude = target.latitude
            writtenLongitude = target.longitude
            enqueue(.activationSucceeded)
        }
        finish(operationID)
    }

    private func clearDeveloperLocation(operationID: UInt64) async {
        guard let services else { return }
        await services.clearDeveloper()
        guard accept(operationID) else { return }
        clearWrittenCoordinate()
        state = .idle
        enqueue(.deactivationSucceeded)
        finish(operationID)
    }

    private func saveThirdParty(
        _ target: FavoriteLocation,
        operationID: UInt64,
        wasActive: Bool,
        selectionRevision: UInt64
    ) async {
        guard let services else { return }
        let radius: Double? = services.routeWaitsForActivation() ? 0 : nil
        do {
            let response = try await performSave(target, randomRadius: radius)
            guard accept(operationID), services.mode() == .thirdParty else { return }
            state = .active
            writtenLatitude = response.latitude
            writtenLongitude = response.longitude
            services.clearThirdPartyFailure()
            logThirdPartySave(services, selectionChanged: selectionRevision != services.selectionRevision())
            enqueue(.activationSucceeded, .offerCommunityContribution)
        } catch {
            guard operationID == self.operationID else { return }
            state = wasActive ? .active : .idle
            logThirdPartyFailure(
                services,
                message: "同步坐标到第三方客户端失败",
                action: "WLOC save",
                recovery: wasActive ? "保留原第三方坐标" : "保持未启用",
                error: error
            )
            services.recordThirdPartyFailure(error)
        }
        finish(operationID)
    }

    private func verifyLocal(
        _ target: FavoriteLocation,
        operationID: UInt64,
        selectionRevision: UInt64
    ) async {
        guard let services else { return }
        let result = await services.verify()
        guard !Task.isCancelled,
              operationID == self.operationID,
              selectionRevision == services.selectionRevision() else {
            if operationID == self.operationID {
                state = services.localSpoofEnabled() ? .active : .idle
                operationTask = nil
            }
            return
        }
        if result.isSuccess {
            applyLocalVerification(target, services: services)
        } else {
            failLocalVerification(result, services: services)
        }
        operationTask = nil
    }

    private func applyLocalVerification(_ target: FavoriteLocation, services: Services) {
        let applied = services.applyVerified(target)
        state = applied ? .active : .idle
        if applied {
            writtenLatitude = target.latitude
            writtenLongitude = target.longitude
            enqueue(.resetLocalDiagnosis, .activationSucceeded)
        }
        RuntimeLogger.info("APP", "定位", "验证结果", details: [
            "success": "true",
            "applied": String(applied),
            "spoofState": String(describing: state)
        ])
    }

    private func failLocalVerification(_ result: VerificationResult, services: Services) {
        state = services.localSpoofEnabled() ? .active : .idle
        RuntimeLogger.warning("APP", "定位", "验证失败", details: [
            "result": result.id,
            "spoofState": String(describing: state)
        ])
        guard result != .verificationInProgress, result != .verificationSuperseded else { return }
        RuntimeLogger.warning("APP", "定位", "开启前检测失败，保持主页并可打开设置", details: [
            "结果": result.id
        ])
        enqueue(.localVerificationFailed(result))
    }

    private func clearThirdParty(operationID: UInt64) async {
        guard let services else { return }
        do {
            try await services.clearThirdParty()
            guard accept(operationID) else { return }
            clearWrittenCoordinate()
            state = .idle
            enqueue(.deactivationSucceeded)
        } catch {
            guard accept(operationID) else { return }
            state = .active
            logThirdPartyFailure(
                services,
                message: "清除第三方客户端坐标失败",
                action: "WLOC clear",
                recovery: "保留已启用状态",
                error: error
            )
            services.recordThirdPartyFailure(error)
        }
        finish(operationID)
    }

    private func writeThirdPartyRoute(
        _ pair: CoordinatePair,
        offsetMeters: Double,
        services: Services
    ) async -> Bool {
        let favorite = FavoriteLocation(name: "路线", coordinatePair: pair, accuracy: services.accuracyMeters())
        do {
            let response = try await performSave(favorite, randomRadius: offsetMeters)
            writtenLatitude = response.latitude ?? pair.wgs84.latitude
            writtenLongitude = response.longitude ?? pair.wgs84.longitude
            services.clearThirdPartyFailure()
            return true
        } catch {
            RuntimeLogger.error("APP", "ThirdPartyProxy", "路线写入第三方坐标失败", error: error, details: [
                "当前客户端": services.thirdPartyClientName(),
                "原因": ThirdPartyProxyError.diagnosis(for: error).title
            ])
            services.recordThirdPartyFailure(error)
            return false
        }
    }

    private func writeLocalRoute(
        _ pair: CoordinatePair,
        offsetMeters: Double,
        services: Services
    ) -> Bool {
        let written = RoutePlayback.offset(pair, radiusMeters: offsetMeters)
        let wgs = written.wgs84
        let applied = services.updateLocalWGS84(wgs.latitude, wgs.longitude, services.accuracyMeters())
        if applied {
            writtenLatitude = wgs.latitude
            writtenLongitude = wgs.longitude
        }
        return applied
    }

    private func queryThirdParty(operationID: UInt64) async {
        guard let services else { return }
        do {
            let response = try await services.queryThirdParty()
            guard accept(operationID) else { return }
            applyQuery(response, services: services)
        } catch {
            guard accept(operationID) else { return }
            state = .idle
            RuntimeLogger.warning("APP", "ThirdPartyProxy", "启动后第三方代理状态查询失败", details: [
                "当前客户端": services.thirdPartyClientName(),
                "请求动作": "WLOC query",
                "错误": error.localizedDescription
            ])
            services.recordThirdPartyFailure(error)
        }
        finish(operationID)
    }

    private func applyQuery(_ response: ThirdPartyProxySettingsResponse, services: Services) {
        if response.success, let latitude = response.latitude, let longitude = response.longitude {
            writtenLatitude = latitude
            writtenLongitude = longitude
            state = .active
            services.clearThirdPartyFailure()
            return
        }
        if response.error?.contains("无已保存") == true {
            clearWrittenCoordinate()
            state = .idle
            services.clearThirdPartyFailure()
            return
        }
        state = .idle
        RuntimeLogger.warning("APP", "ThirdPartyProxy", "第三方代理查询返回失败", details: [
            "当前客户端": services.thirdPartyClientName(),
            "请求动作": "WLOC query",
            "错误": response.error ?? "未知错误"
        ])
        services.recordThirdPartyMessage(response.error ?? "第三方代理查询失败")
    }

    private func performSave(
        _ favorite: FavoriteLocation,
        randomRadius: Double?
    ) async throws -> ThirdPartyProxySettingsResponse {
        guard let services else { throw CancellationError() }
        return try await services.saveThirdParty(favorite, randomRadius)
    }

    private func invalidateOperation() {
        operationTask?.cancel()
        operationTask = nil
        operationID &+= 1
    }

    private func accept(_ operationID: UInt64) -> Bool {
        !Task.isCancelled && operationID == self.operationID
    }

    private func finish(_ operationID: UInt64) {
        guard operationID == self.operationID else { return }
        operationTask = nil
    }

    private func clearWrittenCoordinate() {
        writtenLatitude = nil
        writtenLongitude = nil
    }

    private func enqueue(_ effects: SpoofSessionEffect...) {
        pendingEffects.append(contentsOf: effects)
        effectRevision &+= 1
    }

    private func logThirdPartySave(_ services: Services, selectionChanged: Bool) {
        RuntimeLogger.info("APP", "定位", "第三方代理坐标同步成功", details: [
            "当前客户端": services.thirdPartyClientName(),
            "坐标标准": "WGS-84",
            "客户端模式": "测试模式",
            "选点期间发生变化": String(selectionChanged)
        ])
    }

    private func logThirdPartyFailure(
        _ services: Services,
        message: String,
        action: String,
        recovery: String,
        error: Error
    ) {
        RuntimeLogger.error("APP", "ThirdPartyProxy", message, error: error, details: [
            "当前客户端": services.thirdPartyClientName(),
            "请求动作": action,
            "恢复状态": recovery,
            "原因": ThirdPartyProxyError.diagnosis(for: error).title,
            "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
        ])
    }
}
