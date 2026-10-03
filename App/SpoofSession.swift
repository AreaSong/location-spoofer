import Foundation

enum SpoofSessionEffect: Equatable {
    case activationSucceeded
    case deactivationSucceeded
    case locationApplyFailed(String)
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
        var applyVerified: (FavoriteLocation) -> (latitude: Double, longitude: Double)?
        var updateLocalWGS84: (Double, Double, Int) -> Bool
        var clearLocal: () -> Void
        var saveThirdParty: (FavoriteLocation, Double?) async throws -> ThirdPartyProxySettingsResponse
        var clearThirdParty: () async throws -> Void
        var queryThirdParty: () async throws -> ThirdPartyProxySettingsResponse
        var clearThirdPartyFailure: () -> Void
        var recordThirdPartyFailure: (Error) -> Void
        var recordThirdPartyMessage: (String) -> Void
        var developerSpotWGS84: (Double, Double) -> (latitude: Double, longitude: Double)
        var pushDeveloper: (FavoriteLocation) async -> RouteLocationPushFailure?
        var clearDeveloper: () async -> RouteLocationPushFailure?
        var resumeWrites: () -> Bool = { true }
        var suspendWrites: () -> Void = {}
        var localApplyFailureMessage: () -> String = { "位置更新失败，请重试" }
    }

    @Published private(set) var state: SpoofState
    /// 已经写入代理或第三方客户端的坐标（含随机偏移），不跟随路线播放的插值。
    @Published private(set) var writtenLatitude: Double?
    @Published private(set) var writtenLongitude: Double?
    /// 「切换到此处」比较的目标。随机偏移时这是用户选中的点，不是偏移后的写入值。
    @Published private(set) var switchLatitude: Double?
    @Published private(set) var switchLongitude: Double?
    @Published private(set) var effectRevision: UInt64 = 0

    @Published private(set) var writesSuspended = false
    private(set) var writeGeneration: UInt64 = 0
    private var modeCleanupRunning = false
    private var services: Services?
    private var operationID: UInt64 = 0
    private var operationTask: Task<Void, Never>?
    private var movingWriteTask: Task<Bool, Never>?
    private var movingWriteID: UInt64 = 0
    private var pendingEffects: [SpoofSessionEffect] = []

    init(
        state: SpoofState = .idle,
        writtenLatitude: Double? = nil,
        writtenLongitude: Double? = nil,
        switchLatitude: Double? = nil,
        switchLongitude: Double? = nil
    ) {
        self.state = state
        self.writtenLatitude = writtenLatitude
        self.writtenLongitude = writtenLongitude
        self.switchLatitude = switchLatitude ?? writtenLatitude
        self.switchLongitude = switchLongitude ?? writtenLongitude
    }

    func bind(_ services: Services) {
        self.services = services
    }

    func consumeEffects() -> [SpoofSessionEffect] {
        let effects = pendingEffects
        pendingEffects.removeAll()
        return effects
    }

    /// 路线停下后接管已写入的坐标，不再推送、也不弹出开启成功。
    func adoptActiveLocation(latitude: Double, longitude: Double) {
        state = .active
        remember(
            writtenLatitude: latitude,
            writtenLongitude: longitude,
            switchLatitude: latitude,
            switchLongitude: longitude
        )
    }

    func setPreviewActive(_ active: Bool, latitude: Double?, longitude: Double?) {
        operationTask?.cancel()
        operationTask = nil
        state = active ? .active : .idle
        remember(
            writtenLatitude: active ? latitude : nil,
            writtenLongitude: active ? longitude : nil,
            switchLatitude: active ? latitude : nil,
            switchLongitude: active ? longitude : nil
        )
        effectRevision &+= 1
    }

    /// 设置里清理隧道会话之后：只同步界面，不再向设备发一次 clear。
    func noteExternalClear() {
        services?.pauseRoute()
        invalidateOperation()
        clearWrittenCoordinate()
        state = .idle
    }

    func begin(target: FavoriteLocation, isRouteActivation: Bool = false) {
        guard let services else { return }
        if services.isUseBlocked() { return }
        do {
            try LocationAccuracy.validatedCInt(target.accuracy)
        } catch {
            enqueue(.locationApplyFailed(error.localizedDescription))
            return
        }
        if services.routeIsPlaying() { services.pauseRoute() }
        guard state != .verifying, operationTask == nil else { return }
        guard resumeWrites() else { return }
        let wasActive = state == .active
        if !isRouteActivation { operationID &+= 1 }
        let operationID = operationID
        let selectionRevision = services.selectionRevision()
        state = .verifying
        let pendingWrite = movingWriteTask
        switch services.mode() {
        case .thirdParty:
            operationTask = Task {
                await pendingWrite?.value
                await self.saveThirdParty(
                    target,
                    operationID: operationID,
                    wasActive: wasActive,
                    selectionRevision: selectionRevision
                )
            }
        case .developerTunnel:
            operationTask = Task {
                await pendingWrite?.value
                await self.pushDeveloperLocation(target, operationID: operationID, wasActive: wasActive)
            }
        case .localWiFi:
            operationTask = Task {
                await pendingWrite?.value
                guard self.accept(operationID) else { return }
                await self.verifyLocal(target, operationID: operationID, selectionRevision: selectionRevision)
            }
        }
    }

    func stop() {
        guard !modeCleanupRunning, !(writesSuspended && operationTask != nil),
              let services else { return }
        suspendWrites()
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
        clearWrittenCoordinate()
        state = .idle
        enqueue(.resetLocalDiagnosis, .deactivationSucceeded)
    }

    /// 新意图更换 operationID；writeGeneration 仍专门隔离清除/模式切换。
    /// 已发送成功收据保持唯一真实坐标，但不能驱动旧生产者的地图、门控或错误。
    @discardableResult
    func beginMovement() -> Bool {
        guard resumeWrites() else { return false }
        invalidateOperation()
        return true
    }

    var writtenCoordinate: CoordinatePair? {
        guard let writtenLatitude, let writtenLongitude else { return nil }
        return CoordinateConverter.coordinatePair(
            lat: writtenLatitude, lon: writtenLongitude, mapCoordinateSystem: .wgs84
        )
    }

    func waitForOperation() async {
        await operationTask?.value
    }

    func writeRoute(
        _ pair: CoordinatePair, offsetMeters: Double,
        maySubmit: @escaping () -> Bool = { true },
        onFailure: ((RouteLocationPushFailure) -> Void)? = nil
    ) async -> Bool {
        await writeMovement(pair, offsetMeters: offsetMeters, maySubmit: maySubmit, onFailure: onFailure ?? { _ in })
    }

    /// 真实走动不套随机偏移；调用方停止生产不会取消已发送的收据。
    func writeMoving(_ pair: CoordinatePair, maySubmit: @escaping () -> Bool = { true }) async -> Bool {
        await writeMovement(pair, offsetMeters: 0, maySubmit: maySubmit, onFailure: nil)
    }

    private func writeMovement(
        _ pair: CoordinatePair, offsetMeters: Double,
        maySubmit: @escaping () -> Bool, onFailure: ((RouteLocationPushFailure) -> Void)?
    ) async -> Bool {
        guard let services else { return false }
        let generation = writeGeneration
        let intent = operationID
        let mode = services.mode()
        guard accept(intent), acceptsWrite(generation: generation, mode: mode), maySubmit() else { return false }
        // 前台查询不插队；已存在的查询先收尾，避免查询结果覆盖移动写入。
        await operationTask?.value
        // 路线、走动与显式换点共用此屏障。等待期间新意图会淘汰旧请求。
        while let pending = movingWriteTask {
            await pending.value
            guard accept(intent), acceptsWrite(generation: generation, mode: mode), maySubmit() else { return false }
        }
        guard accept(intent), acceptsWrite(generation: generation, mode: mode), maySubmit(), !services.isUseBlocked() else { return false }
        movingWriteID &+= 1
        let id = movingWriteID
        let task = Task {
            defer { if self.movingWriteID == id { self.movingWriteTask = nil } }
            guard self.accept(intent), self.acceptsWrite(generation: generation, mode: mode), maySubmit() else { return false }
            switch mode {
            case .thirdParty:
                return await self.writeThirdPartyRoute(pair, offsetMeters: offsetMeters, services: services)
            case .developerTunnel:
                let written = RoutePlayback.offset(pair, radiusMeters: offsetMeters)
                return await self.writeDeveloperMoving(written, services: services, onFailure: onFailure)
            case .localWiFi:
                return self.writeLocalRoute(pair, offsetMeters: offsetMeters, services: services)
            }
        }
        movingWriteTask = task
        let applied = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if movingWriteID == id { movingWriteTask = nil }
        return applied && accept(intent) && acceptsWrite(generation: generation, mode: mode)
    }

    func refreshThirdParty() {
        guard let services, services.mode() == .thirdParty, operationTask == nil,
              movingWriteTask == nil, !writesSuspended else { return }
        let operationID = operationID
        operationTask = Task { await self.queryThirdParty(operationID: operationID) }
    }

    @discardableResult
    func resumeWrites() -> Bool {
        guard !modeCleanupRunning, let services, services.resumeWrites() else { return false }
        writesSuspended = false
        return true
    }

    func suspendWrites() {
        writeGeneration &+= 1
        writesSuspended = true
        services?.pauseRoute()
        invalidateOperation()
        // 取消了验证任务就不能继续显示验证中；清理本身由独立状态表示。
        if state == .verifying {
            state = writtenLatitude == nil ? .idle : .active
        }
        services?.suspendWrites()
    }

    var writeMode: ProxyRuntimeMode? { services?.mode() }
    var writeIntent: UInt64 { operationID }

    func waitForMovementWrite() async {
        await movingWriteTask?.value
    }

    func acceptsWrite(generation: UInt64, mode: ProxyRuntimeMode) -> Bool {
        !Task.isCancelled && !writesSuspended && generation == writeGeneration && services?.mode() == mode
    }

    /// 设置页在第一次 await 前调用，失败也不重新启动旧生产者。
    func beginModeCleanup() {
        modeCleanupRunning = true
        suspendWrites()
    }

    func endModeCleanup() {
        modeCleanupRunning = false
    }

    func cancelForModeChange() {
        guard let services else { return }
        writeGeneration &+= 1
        writesSuspended = true
        invalidateOperation()
        clearWrittenCoordinate()
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
        guard accept(operationID), !writesSuspended, let services else { return }
        let original = target.coordinatePair.wgs84
        let shifted = services.developerSpotWGS84(original.latitude, original.longitude)
        let pushed = FavoriteLocation(
            name: target.name,
            coordinatePair: CoordinateConverter.coordinatePair(
                lat: shifted.latitude,
                lon: shifted.longitude,
                mapCoordinateSystem: .wgs84
            ),
            accuracy: target.accuracy
        )
        let failure = await services.pushDeveloper(pushed)
        guard accept(operationID), services.mode() == .developerTunnel else { return }
        if failure == .superseded {
            finish(operationID)
            return
        }
        if let failure {
            state = wasActive ? .active : .idle
            enqueue(.developerPushFailed(failure.message))
        } else {
            state = .active
            remember(
                writtenLatitude: shifted.latitude,
                writtenLongitude: shifted.longitude,
                switchLatitude: original.latitude,
                switchLongitude: original.longitude
            )
            enqueue(.activationSucceeded)
        }
        finish(operationID)
    }

    private func clearDeveloperLocation(operationID: UInt64) async {
        guard let services else { return }
        let failure = await services.clearDeveloper()
        guard accept(operationID) else { return }
        if failure == .superseded {
            finish(operationID)
            return
        }
        if let failure {
            state = .active
            enqueue(.developerPushFailed(failure.message))
            finish(operationID)
            return
        }
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
        guard accept(operationID), !writesSuspended, let services else { return }
        let radius: Double? = services.routeWaitsForActivation() ? 0 : nil
        do {
            let response = try await performSave(target, randomRadius: radius)
            guard accept(operationID), services.mode() == .thirdParty else { return }
            state = .active
            remember(
                writtenLatitude: response.latitude,
                writtenLongitude: response.longitude,
                switchLatitude: target.latitude,
                switchLongitude: target.longitude
            )
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
        guard let written = services.applyVerified(target) else {
            state = services.localSpoofEnabled() ? .active : .idle
            enqueue(.locationApplyFailed(services.localApplyFailureMessage()))
            RuntimeLogger.info("APP", "定位", "验证结果", details: [
                "success": "true",
                "applied": "false",
                "spoofState": String(describing: state)
            ])
            return
        }
        state = .active
        remember(
            writtenLatitude: written.latitude,
            writtenLongitude: written.longitude,
            switchLatitude: target.latitude,
            switchLongitude: target.longitude
        )
        enqueue(.resetLocalDiagnosis, .activationSucceeded)
        RuntimeLogger.info("APP", "定位", "验证结果", details: [
            "success": "true",
            "applied": "true",
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
        let intent = operationID
        let generation = writeGeneration
        let mode = services.mode()
        let favorite = FavoriteLocation(name: "路线", coordinatePair: pair, accuracy: services.accuracyMeters())
        do {
            let response = try await performSave(favorite, randomRadius: offsetMeters)
            guard acceptsWrite(generation: generation, mode: mode) else { return false }
            // 所有新写入都排在此调用之后；即使生产者已换代，这仍是设备最新成功位置。
            let latitude = response.latitude ?? pair.wgs84.latitude
            let longitude = response.longitude ?? pair.wgs84.longitude
            remember(
                writtenLatitude: latitude,
                writtenLongitude: longitude,
                switchLatitude: latitude,
                switchLongitude: longitude
            )
            if accept(intent) { services.clearThirdPartyFailure() }
            return true
        } catch {
            guard accept(intent), acceptsWrite(generation: generation, mode: mode),
                  !(error is CancellationError) else { return false }
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
            remember(
                writtenLatitude: wgs.latitude,
                writtenLongitude: wgs.longitude,
                switchLatitude: wgs.latitude,
                switchLongitude: wgs.longitude
            )
        }
        return applied
    }

    private func writeDeveloperMoving(
        _ pair: CoordinatePair, services: Services, onFailure: ((RouteLocationPushFailure) -> Void)?
    ) async -> Bool {
        let intent = operationID
        let generation = writeGeneration
        let favorite = FavoriteLocation(
            name: "真实走动",
            coordinatePair: pair,
            accuracy: services.accuracyMeters()
        )
        let failure = await services.pushDeveloper(favorite)
        guard acceptsWrite(generation: generation, mode: .developerTunnel) else { return false }
        if failure == .superseded { return false }
        if let failure {
            guard accept(intent) else { return false }
            if let onFailure { onFailure(failure) }
            else { enqueue(.developerPushFailed(failure.message)) }
            return false
        }
        let wgs = pair.wgs84
        remember(
            writtenLatitude: wgs.latitude,
            writtenLongitude: wgs.longitude,
            switchLatitude: wgs.latitude,
            switchLongitude: wgs.longitude
        )
        return true
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
            remember(
                writtenLatitude: latitude,
                writtenLongitude: longitude,
                switchLatitude: latitude,
                switchLongitude: longitude
            )
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
        remember(writtenLatitude: nil, writtenLongitude: nil, switchLatitude: nil, switchLongitude: nil)
    }

    private func remember(
        writtenLatitude: Double?,
        writtenLongitude: Double?,
        switchLatitude: Double?,
        switchLongitude: Double?
    ) {
        self.writtenLatitude = writtenLatitude
        self.writtenLongitude = writtenLongitude
        self.switchLatitude = switchLatitude
        self.switchLongitude = switchLongitude
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
