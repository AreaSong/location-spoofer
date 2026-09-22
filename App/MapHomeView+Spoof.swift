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

    var buttonTitle: String {
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

    var buttonColor: Color {
        switch spoofState {
        case .idle: return .blue
        case .verifying: return .gray
        case .active: return .green
        }
    }

    func handleMainButtonTap() {
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
        LocationUseAvailability.current(
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

    var signingExpiryMapMessage: String? {
        let status = signingExpiryStatus
        guard !status.isExpired,
              let message = status.mapBannerMessage,
              let expiration = status.expirationDate,
              !signingExpiryBanner.isBannerDismissed(expirationDate: expiration, now: Date()) else {
            return nil
        }
        return message
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func signingExpiryBannerView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showSigningResignSheet = true
            } label: {
                Label(message, systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            HStack {
                Button("如何重签") {
                    showSigningResignSheet = true
                }
                .font(.footnote.weight(.semibold))
                if let expiration = signingExpiryStatus.expirationDate {
                    Button("今天不再提示") {
                        signingExpiryBanner.dismissBanner(expirationDate: expiration, now: Date())
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func beginLocationOperation(target overrideTarget: FavoriteLocation? = nil) {
        if locationUseBlock != nil {
            return
        }
        if route.phase == .playing {
            route.pause()
        }
        guard spoofState != .verifying, locationOperationTask == nil else { return }
        let wasActive = spoofState == .active
        locationOperationID &+= 1
        let operationID = locationOperationID
        let selectionRevision = mapState.selection.revision
        let target = overrideTarget ?? currentSelectionFavorite
        spoofState = .verifying

        locationOperationTask = Task { @MainActor in
            if runtimeMode.mode == .thirdParty {
                do {
                    let response = try await thirdPartyProxy.save(
                        target,
                        randomRadius: route.waitingForActivation ? 0 : nil
                    )
                    guard !Task.isCancelled,
                          operationID == locationOperationID,
                          runtimeMode.mode == .thirdParty else {
                        return
                    }
                    // The remote write has already succeeded. If the user moved
                    // the map meanwhile, keep this target active and let
                    // needsSwitchButton offer syncing the newer selection.
                    spoofState = .active
                    activeSpoofLat = response.latitude
                    activeSpoofLon = response.longitude
                    runtimeFailure.clearThirdParty()
                    RuntimeLogger.info("APP", "定位", "第三方代理坐标同步成功", details: [
                        "当前客户端": thirdPartyClient.selectedClient.name,
                        "坐标标准": "WGS-84",
                        "客户端模式": "测试模式",
                        "选点期间发生变化": String(selectionRevision != mapState.selection.revision)
                    ])
                    presentSuccessfulOperationTip(.activation)
                    queueCommunityContributionPrompt(for: thirdPartyClient.selectedClient)
                } catch {
                    guard operationID == locationOperationID else { return }
                    // A failed replacement does not clear the coordinate that
                    // was already persisted inside the third-party client.
                    spoofState = wasActive ? .active : .idle
                    RuntimeLogger.error(
                        "APP",
                        "ThirdPartyProxy",
                        "同步坐标到第三方客户端失败",
                        error: error,
                        details: [
                            "当前客户端": thirdPartyClient.selectedClient.name,
                            "请求动作": "WLOC save",
                            "恢复状态": wasActive ? "保留原第三方坐标" : "保持未启用",
                            "原因": ThirdPartyProxyError.diagnosis(for: error).title,
                            "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
                        ]
                    )
                    runtimeFailure.recordThirdParty(error: error)
                }
                if operationID == locationOperationID {
                    locationOperationTask = nil
                }
                return
            }

            let result = await setup.runVerificationTest()
            guard !Task.isCancelled,
                  operationID == locationOperationID,
                  selectionRevision == mapState.selection.revision else {
                if operationID == locationOperationID {
                    spoofState = actions.virtualLocationEnabled ? .active : .idle
                    locationOperationTask = nil
                }
                return
            }

            if result.isSuccess {
                let applied = actions.applyVerified(target)
                spoofState = applied ? .active : .idle
                if applied {
                    activeSpoofLat = target.latitude
                    activeSpoofLon = target.longitude
                    lastSpoofDiagnosisSystem = nil
                    hasLoggedSpoofDiagnosis = false
                }
                RuntimeLogger.info("APP", "定位", "验证结果", details: [
                    "success": "true",
                    "applied": String(applied),
                    "spoofState": String(describing: spoofState)
                ])
                if applied {
                    presentSuccessfulOperationTip(.activation)
                }
            } else {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
                RuntimeLogger.warning("APP", "定位", "验证失败", details: [
                    "result": result.id,
                    "spoofState": String(describing: spoofState)
                ])
                if result != .verificationInProgress,
                   result != .verificationSuperseded {
                    RuntimeLogger.warning("APP", "定位", "开启前检测失败，保持主页并可打开设置", details: [
                        "结果": result.id
                    ])
                    activeTip = nil
                    setup.applyVerificationResult(result, presentSetup: false)
                }
            }
            locationOperationTask = nil
        }
    }

    func stopSpoofing() {
        route.pause()
        locationOperationTask?.cancel()
        locationOperationTask = nil
        locationOperationID &+= 1
        if runtimeMode.mode == .thirdParty {
            spoofState = .verifying
            locationOperationTask = Task { @MainActor in
                do {
                    try await thirdPartyProxy.clear()
                    spoofState = .idle
                    activeSpoofLat = nil
                    activeSpoofLon = nil
                    presentSuccessfulOperationTip(.deactivation)
                } catch {
                    spoofState = .active
                    RuntimeLogger.error(
                        "APP",
                        "ThirdPartyProxy",
                        "清除第三方客户端坐标失败",
                        error: error,
                        details: [
                            "当前客户端": thirdPartyClient.selectedClient.name,
                            "请求动作": "WLOC clear",
                            "恢复状态": "保留已启用状态",
                            "原因": ThirdPartyProxyError.diagnosis(for: error).title,
                            "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
                        ]
                    )
                    runtimeFailure.recordThirdParty(error: error)
                }
                locationOperationTask = nil
            }
            return
        }

        actions.clear()
        spoofState = .idle
        activeSpoofLat = nil
        activeSpoofLon = nil
        lastSpoofDiagnosisSystem = nil
        hasLoggedSpoofDiagnosis = false
        presentSuccessfulOperationTip(.deactivation)
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

    var homeRuntimeStatusText: String {
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
        return keepAlive.isHealthy ? "代理运行中 · 保活正常" : "代理运行中 · 保活中断"
    }

    func registerWiFiChangeObserver() {
        guard runtimeMode.mode == .localWiFi else { return }
        guard wifiChangeObserverToken == nil else { return }
        wifiChangeObserverToken = net.observeWiFiChanges { [self] reason in
            handleWiFiChange(reason: reason)
        }
    }

    func refreshThirdPartyState() {
        guard runtimeMode.mode == .thirdParty,
              locationOperationTask == nil else { return }
        locationOperationTask = Task { @MainActor in
            do {
                let response = try await thirdPartyProxy.query()
                if response.success,
                   let latitude = response.latitude,
                   let longitude = response.longitude {
                    activeSpoofLat = latitude
                    activeSpoofLon = longitude
                    spoofState = .active
                    runtimeFailure.clearThirdParty()
                } else if response.error?.contains("无已保存") == true {
                    activeSpoofLat = nil
                    activeSpoofLon = nil
                    spoofState = .idle
                    runtimeFailure.clearThirdParty()
                } else {
                    spoofState = .idle
                    RuntimeLogger.warning("APP", "ThirdPartyProxy", "第三方代理查询返回失败", details: [
                        "当前客户端": thirdPartyClient.selectedClient.name,
                        "请求动作": "WLOC query",
                        "错误": response.error ?? "未知错误"
                    ])
                    runtimeFailure.recordThirdParty(message: response.error ?? "第三方代理查询失败")
                }
            } catch {
                spoofState = .idle
                RuntimeLogger.warning("APP", "ThirdPartyProxy", "启动后第三方代理状态查询失败", details: [
                    "当前客户端": thirdPartyClient.selectedClient.name,
                    "请求动作": "WLOC query",
                    "连接状态": String(describing: thirdPartyProxy.connectionState),
                    "错误": error.localizedDescription
                ])
                runtimeFailure.recordThirdParty(error: error)
            }
            locationOperationTask = nil
        }
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
