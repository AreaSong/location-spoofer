import SwiftUI
import MapKit
import UIKit
import CoreLocation

extension MapHomeView {
    var needsSwitchButton: Bool {
        SpoofSelectionSwitch.needsSwitch(
            isActive: spoofState == .active,
            writtenLatitude: activeSpoofLat,
            writtenLongitude: activeSpoofLon,
            selection: currentSelectionFavorite.coordinatePair
        )
    }

    /// 隧道还没连上时，主按钮先引导去连隧道，点击行为不变（打开路线定位）。
    var needsTunnelBeforeStart: Bool {
        runtimeMode.mode == .developerTunnel
            && routeLocation.readiness != .ready
            && spoofState == .idle
    }

    var buttonSystemImage: String? {
        needsTunnelBeforeStart ? "network" : nil
    }

    var buttonTitle: String {
        if needsTunnelBeforeStart {
            return "先连接隧道"
        }
        if runtimeMode.mode == .thirdParty {
            switch spoofState {
            case .idle: return "同步到第三方代理"
            case .verifying: return "检测并同步中…"
            case .active: return "停止第三方虚拟定位"
            }
        }
        switch spoofState {
        case .idle: return "开始虚拟定位"
        case .verifying: return "验证环境中…"
        case .active: return "停止虚拟定位"
        }
    }

    var spotPeekTitle: String {
        if needsSwitchButton { return "切换到此处" }
        if needsTunnelBeforeStart { return "连接隧道" }
        if runtimeMode.mode == .thirdParty {
            switch spoofState {
            case .idle: return "同步"
            case .verifying: return "同步中"
            case .active: return "停止"
            }
        }
        switch spoofState {
        case .idle: return "开始"
        case .verifying: return "验证中"
        case .active: return "停止"
        }
    }

    var spotPeekAccessibilityLabel: String {
        needsSwitchButton ? "切换到此处" : buttonTitle
    }

    var buttonColor: Color {
        switch spoofState {
        case .idle: return .blue
        case .verifying: return .gray
        case .active: return .green
        }
    }

    func handleMainButtonTap() {
        if UIPreview.isEnabled() {
            if spoofState == .active, !needsSwitchButton {
                session.setPreviewActive(false, latitude: nil, longitude: nil)
            } else {
                beginLocationOperation()
            }
            return
        }
        if runtimeMode.mode == .developerTunnel, spoofState != .active {
            routeLocation.refresh()
            if routeLocation.readiness != .ready {
                showRouteLocationSetup = true
                return
            }
        }
        switch spoofState {
        case .idle:
            beginLocationOperation()
        case .active:
            stopSpoofing()
        case .verifying:
            break
        }
    }

    var locationUseBlock: LocationUseBlock? {
        if UIPreview.isEnabled() { return nil }
        return LocationUseAvailability.current(
            mode: runtimeMode.mode,
            wifiEnabled: net.isWiFiEnabled,
            cellularEnabled: net.usesCellular,
            runtimeFailure: runtimeFailure.failure,
            signing: signingExpiryStatus
        )
    }

    var signingExpiryStatus: SigningExpiryStatus {
        _ = signingExpiryBanner.revision
        return SigningExpiry.current()
    }

    func locationUnavailableOverlay(_ block: LocationUseBlock) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(LocationUseBlock.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(block.message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(LocationUseBlock.openSettingsTitle) {
                activeSheet = .settings
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }

    func beginLocationOperation(target overrideTarget: FavoriteLocation? = nil) {
        if UIPreview.isEnabled() {
            let coordinate = (overrideTarget?.coordinatePair ?? currentSelectionPair).wgs84
            session.setPreviewActive(true, latitude: coordinate.latitude, longitude: coordinate.longitude)
            return
        }
        session.begin(target: overrideTarget ?? currentSelectionFavorite)
    }

    func stopSpoofing() {
        session.stop()
    }

    func handleSpoofEffects(_ effects: [SpoofSessionEffect]) {
        for effect in effects {
            switch effect {
            case .activationSucceeded:
                presentSuccessfulOperationTip(.activation)
            case .deactivationSucceeded:
                presentSuccessfulOperationTip(.deactivation)
            case .offerCommunityContribution:
                queueCommunityContributionPrompt(for: thirdPartyClient.selectedClient)
            case .developerPushFailed(let message):
                developerLocationError = message
                spotIslandFailed = true
                syncRouteActivity()
            case .localVerificationFailed(let result):
                activeTip = nil
                spotIslandFailed = true
                setup.applyVerificationResult(result, presentSetup: false)
                syncRouteActivity()
            case .resetLocalDiagnosis:
                lastSpoofDiagnosisSystem = nil
                hasLoggedSpoofDiagnosis = false
            }
        }
    }

    static func makeSpoofSession(
        setup: SetupCoordinator,
        actions: LocationActionCoordinator,
        route: RoutePlaybackController,
        mapState: MapLocationState
    ) -> SpoofSession {
        var initialState = SpoofState.idle
        var initialLatitude: Double?
        var initialLongitude: Double?
        if ProxyRuntimeModeStore.shared.mode == .localWiFi,
           let settings = WlocSettingsStore.load(), settings.enabled {
            initialState = .active
            initialLatitude = settings.latitude
            initialLongitude = settings.longitude
        }
        let session = SpoofSession(
            state: initialState,
            writtenLatitude: initialLatitude,
            writtenLongitude: initialLongitude
        )
        session.bind(spoofServices(setup: setup, actions: actions, route: route, mapState: mapState))
        return session
    }

    private static func spoofServices(
        setup: SetupCoordinator,
        actions: LocationActionCoordinator,
        route: RoutePlaybackController,
        mapState: MapLocationState
    ) -> SpoofSession.Services {
        let thirdParty = ThirdPartyProxyManager.shared
        let failure = LocationRuntimeFailureStore.shared
        let client = ThirdPartyProxyClientStore.shared
        return SpoofSession.Services(
            mode: { ProxyRuntimeModeStore.shared.mode },
            isUseBlocked: {
                LocationUseAvailability.current(
                    mode: ProxyRuntimeModeStore.shared.mode,
                    wifiEnabled: NetworkMonitor.shared.isWiFiEnabled,
                    cellularEnabled: NetworkMonitor.shared.usesCellular,
                    runtimeFailure: failure.failure,
                    signing: SigningExpiry.current()
                ) != nil
            },
            selectionRevision: { mapState.selection.revision },
            localSpoofEnabled: { actions.virtualLocationEnabled },
            thirdPartyClientName: { client.selectedClient.name },
            routeIsPlaying: { route.phase == .playing },
            routeWaitsForActivation: { route.waitingForActivation },
            routeOffsetMeters: { route.offsetMeters },
            accuracyMeters: { LocationAccuracyStore.shared.meters },
            pauseRoute: { route.pause() },
            verify: { await setup.runVerificationTest() },
            applyVerified: { actions.applyVerified($0) },
            updateLocalWGS84: { latitude, longitude, accuracy in
                actions.updateSpoofedWGS84(latitude: latitude, longitude: longitude, accuracy: accuracy)
            },
            clearLocal: { actions.clear() },
            saveThirdParty: { favorite, randomRadius in
                try await thirdParty.save(favorite, randomRadius: randomRadius)
            },
            clearThirdParty: { try await thirdParty.clear() },
            queryThirdParty: { try await thirdParty.query() },
            clearThirdPartyFailure: { failure.clearThirdParty() },
            recordThirdPartyFailure: { failure.recordThirdParty(error: $0) },
            recordThirdPartyMessage: { failure.recordThirdParty(message: $0) },
            pushDeveloper: { favorite in
                await RouteLocationSetupStore.shared.set(
                    latitude: favorite.latitude,
                    longitude: favorite.longitude
                )
            },
            clearDeveloper: {
                await RouteLocationSetupStore.shared.clear()
            }
        )
    }

    func presentSuccessfulOperationTip(_ kind: VirtualLocationTipKind) {
        let count = tipPreferences.recordSuccessfulOperation(kind)
        let operationName = kind == .activation ? "开启" : "关闭"
        RuntimeLogger.info("APP", "提醒", "累计\(operationName)虚拟定位次数", details: [
            "次数": String(count),
            "运行模式": runtimeMode.mode.displayName,
            "可显示不再提醒": String(tipPreferences.canSuppress(kind))
        ])
        guard tipPreferences.shouldPresentAutomaticTip(kind) else { return }
        switch kind {
        case .activation:
            showEnableTip = true
        case .deactivation:
            showDisableTip = true
        }
    }

    func queueCommunityContributionPrompt(for client: ThirdPartyProxyClient) {
        guard remoteConfiguration.requestsCommunityPrompt(for: client),
              communityPromptPreferences.shouldPresent() else {
            return
        }
        communityPromptPreferences.recordPresentation()
        if showEnableTip {
            pendingCommunityContributionClient = client
        } else {
            communityContributionClient = client
        }
    }

    func openCommunityContributionPage() {
        githubDestination = SafariDestination(url: GitHubSubmission.communityContributionURL)
    }

    var homeRuntimeStatusTone: StatusPill.Tone {
        if UIPreview.isEnabled() { return .neutral }
        if runtimeMode.mode == .developerTunnel {
            return routeLocation.readiness == .ready ? .ok : .warn
        }
        if runtimeMode.mode == .thirdParty {
            switch thirdPartyProxy.connectionState {
            case .unknown: return .neutral
            case .connected: return .ok
            case .failed: return .error
            }
        }
        if !proxy.isRunning {
            return .error
        }
        return keepAlive.isHealthy ? .ok : .warn
    }

    var homeRuntimeStatusText: String {
        if UIPreview.isEnabled() { return "开发者模式" }
        if runtimeMode.mode == .developerTunnel {
            return routeLocation.readiness == .ready ? "隧道已连接" : "隧道未就绪"
        }
        if runtimeMode.mode == .thirdParty {
            switch thirdPartyProxy.connectionState {
            case .unknown: return "未检测"
            case .connected: return "模块已连接"
            case .failed: return "连接失败"
            }
        }
        if !proxy.isRunning {
            return "代理未运行"
        }
        return keepAlive.isHealthy ? "代理正常" : "保活中断"
    }

    func registerWiFiChangeObserver() {
        guard runtimeMode.mode == .localWiFi else { return }
        guard wifiChangeObserverToken == nil else { return }
        wifiChangeObserverToken = net.observeWiFiChanges { [self] reason in
            handleWiFiChange(reason: reason)
        }
    }

    func refreshThirdPartyState() {
        session.refreshThirdParty()
    }

    func handleWiFiChange(reason: WiFiChangeReason) {
        RuntimeLogger.info("APP", "WiFi", "检测到 Wi-Fi 网络变化", details: [
            "原因": reason.rawValue,
            "虚拟定位已开启": String(spoofState == .active)
        ])
        guard spoofState == .active else { return }
        if wifiVerificationTask != nil {
            RuntimeLogger.info("APP", "WiFi", "网络仍在变化，重新计算环境检测等待时间")
        }
        wifiVerificationTask?.cancel()
        let verificationID = UUID()
        wifiVerificationID = verificationID
        wifiVerificationTask = Task { @MainActor in
            defer {
                if wifiVerificationID == verificationID {
                    wifiVerificationTask = nil
                    wifiVerificationID = nil
                }
            }
            let stabilizationNanoseconds: UInt64 = 3_000_000_000
            RuntimeLogger.info("APP", "WiFi", "等待 Wi-Fi 连接稳定后检测", details: [
                "等待秒数": "3",
                "事件原因": reason.rawValue
            ])
            do {
                try await Task.sleep(nanoseconds: stabilizationNanoseconds)
            } catch {
                RuntimeLogger.debug("APP", "WiFi", "延时检测已被更新的网络事件取消")
                return
            }
            guard !Task.isCancelled, spoofState == .active else { return }
            guard net.isSatisfied, net.isWiFiEnabled else {
                RuntimeLogger.warning("APP", "WiFi", "稳定等待结束后仍未连接 Wi-Fi，主页提示当前不能使用", details: [
                    "网络可用": String(net.isSatisfied),
                    "Wi-Fi接口": String(net.isWiFiEnabled)
                ])
                activeTip = nil
                return
            }

            // A manual diagnostics request can occupy the verifier for its full
            // eight-second URL timeout. Wait long enough to run this check after
            // it finishes instead of silently dropping the Wi-Fi-change check.
            let maximumAttempts = 11
            for attempt in 1...maximumAttempts {
                RuntimeLogger.info("APP", "WiFi", "开始后台环境检测", details: [
                    "尝试": "\(attempt)/\(maximumAttempts)",
                    "SSID可读取": String(net.currentSSID != nil)
                ])
                let result = await setup.runVerificationTest()
                guard !Task.isCancelled, spoofState == .active else { return }
                if result == .verificationInProgress, attempt < maximumAttempts {
                    RuntimeLogger.info("APP", "WiFi", "已有环境检测运行，1 秒后重试", details: [
                        "尝试": "\(attempt)/\(maximumAttempts)"
                    ])
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                RuntimeLogger.info("APP", "WiFi", "后台环境检测完成", details: [
                    "结果": result.id,
                    "success": String(result.isSuccess)
                ])
                if !result.isSuccess,
                   result != .verificationInProgress,
                   result != .verificationSuperseded {
                    activeTip = nil
                    setup.applyVerificationResult(result, presentSetup: false)
                } else if result == .verificationInProgress {
                    RuntimeLogger.warning("APP", "WiFi", "环境检测连续被占用，本次不重复弹窗")
                }
                return
            }
        }
    }

    var enableTipSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ActivationTipContent(runtimeMode: runtimeMode.mode, dismiss: {})
                }.padding(16)
            }
            .navigationTitle("虚拟定位已开启").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if tipPreferences.canSuppress(.activation) {
                        Button {
                            tipPreferences.suppress(.activation)
                            showEnableTip = false
                        } label: {
                            Label("不再提醒", systemImage: "bell.slash.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button { showEnableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button { showEnableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    var disableTipSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DeactivationTipContent(runtimeMode: runtimeMode.mode, dismiss: {})
                    if runtimeMode.mode == .localWiFi {
                        RemoveProxyTipContent(dismiss: {})
                    }
                }.padding(16)
            }
            .navigationTitle("虚拟定位已关闭").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if tipPreferences.canSuppress(.deactivation) {
                        Button {
                            tipPreferences.suppress(.deactivation)
                            showDisableTip = false
                        } label: {
                            Label("不再提醒", systemImage: "bell.slash.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button { showDisableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button { showDisableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}
