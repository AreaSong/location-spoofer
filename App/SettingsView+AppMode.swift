import SwiftUI

extension SettingsView {
    var proxyBinding: Binding<Bool> {
        Binding(get: { proxy.isRunning }, set: { on in
            Task {
                if on {
                    do {
                        try await proxy.start()
                    } catch {
                        proxy.error = error.localizedDescription
                        proxyOperationAlertTitle = "代理操作失败"
                        proxyOperationError = error.localizedDescription
                    }
                } else {
                    if actions.virtualLocationEnabled {
                        actions.clear()
                        RuntimeLogger.info("APP", "Settings", "关闭代理前已同步关闭虚拟定位")
                    }
                    proxy.stop()
                }
            }
        })
    }

    var appModeNetworkBlockedMessage: String? {
        AppModeNetworkRequirement.blockedMessage(net.appModeNetworkStatus)
    }

    func switchRuntimeMode(to newMode: ProxyRuntimeMode) {
        guard newMode != runtimeMode.mode, !modeOperationRunning else { return }
        if newMode == .localWiFi, let message = appModeNetworkBlockedMessage {
            proxyOperationAlertTitle = AppModeNetworkRequirement.title
            proxyOperationError = message
            return
        }
        modeOperationRunning = true
        Task { @MainActor in
            defer { modeOperationRunning = false }
            let cleanup = RuntimeModeSwitchCleanup.required(from: runtimeMode.mode, to: newMode)
            if cleanup.contains(.developerSimulation) {
                if let failure = await RouteLocationSetupStore.shared.clear() {
                    presentDeveloperSimulationClearBlocked(failure)
                    return
                }
            }
            if cleanup.contains(.thirdPartyWLOC) {
                do {
                    try await thirdPartyProxy.clear()
                } catch {
                    presentThirdPartyCoordinateClearBlocked(destination: newMode, error: error)
                    return
                }
            }
            switch newMode {
            case .thirdParty:
                if actions.virtualLocationEnabled { actions.clear() }
                proxy.stop()
                setup.completeSetup()
                runtimeMode.setMode(.thirdParty)
                ThirdPartyModuleRuntime.syncServerWithDistribution()
                if runtimeMode.isInitialized(.thirdParty) {
                    do {
                        _ = try await thirdPartyProxy.query()
                        runtimeFailure.clearThirdParty()
                        proxyOperationAlertTitle = "模式已切换"
                        proxyOperationError = "第三方代理模式检测通过。请关闭 Wi-Fi 中的 127.0.0.1:8888 手动代理，避免双重拦截。"
                    } catch {
                        presentThirdPartyUnavailable(for: error)
                    }
                } else {
                    setup.requestThirdPartyOnboarding()
                    dismiss()
                }
            case .developerTunnel:
                if actions.virtualLocationEnabled { actions.clear() }
                proxy.stop()
                ThirdPartyModuleRuntime.shutdown()
                runtimeMode.setMode(.developerTunnel)
                if runtimeMode.isInitialized(.developerTunnel) {
                    proxyOperationAlertTitle = "模式已切换"
                    proxyOperationError = "已切换到开发者隧道模式。请确认 LocalDevVPN 隧道已连接，并已导入配对文件。"
                } else {
                    setup.requestDeveloperOnboarding()
                    dismiss()
                }
            case .localWiFi:
                ThirdPartyModuleRuntime.shutdown()
                runtimeMode.setMode(.localWiFi)
                await setup.prepareLocalServices()
                if runtimeMode.isInitialized(.localWiFi) {
                    let result = await setup.runVerificationTest()
                    setup.applyVerificationResult(result, presentSetup: false)
                    if result.isSuccess {
                        proxyOperationAlertTitle = "模式已切换"
                        proxyOperationError = "APP 模式环境检测通过。请停用第三方 WLOC 模块或代理连接，避免双重拦截。"
                    }
                } else {
                    setup.requestSetup()
                    dismiss()
                }
            }
        }
    }

    func presentThirdPartyCoordinateClearBlocked(destination: ProxyRuntimeMode, error: Error) {
        let diagnosis = ThirdPartyProxyError.diagnosis(for: error)
        let followUp: String
        switch destination {
        case .localWiFi:
            followUp = "请处理后重试，避免旧坐标与 APP 模式同时拦截。"
        case .developerTunnel:
            followUp = "请处理后重试，避免第三方客户端中的旧坐标在开发者隧道模式下继续生效。"
        case .thirdParty:
            followUp = "请处理后重试。"
        }
        RuntimeLogger.warning("APP", "Mode", "切换模式前无法清除第三方坐标", details: [
            "目标模式": destination.displayName,
            "错误": error.localizedDescription,
            "原因": diagnosis.title,
            "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
        ])
        proxyOperationAlertTitle = destination == .localWiFi
            ? "未能切换到 APP 模式"
            : "未能切换到\(destination.displayName)"
        proxyOperationError = "无法清除第三方客户端坐标，已保持当前模式。\(diagnosis.summary) \(followUp)"
    }

    func presentDeveloperSimulationClearBlocked(_ failure: RouteLocationPushFailure) {
        RuntimeLogger.warning("APP", "Mode", "切换模式前无法关闭系统模拟定位", details: [
            "错误": failure.message
        ])
        proxyOperationAlertTitle = "未能切换模式"
        proxyOperationError = "无法关闭系统模拟定位，已保持开发者隧道模式。\(failure.message)"
    }

    func presentThirdPartyUnavailable(for error: Error) {
        runtimeFailure.recordThirdParty(error: error)
        proxyOperationAlertTitle = LocationUseBlock.title
        proxyOperationError = ThirdPartyProxyError.diagnosis(for: error).summary
    }

    func resetCertificateAuthority() {
        guard runtimeMode.mode == .localWiFi, !modeOperationRunning else { return }
        modeOperationRunning = true
        Task { @MainActor in
            defer { modeOperationRunning = false }
            if actions.virtualLocationEnabled {
                actions.clear()
            }
            proxy.stop()
            do {
                try setup.certificateStore.reset()
                runtimeMode.resetInitialization(.localWiFi)
                guard await setup.prepareLocalServices() else {
                    proxyOperationAlertTitle = "证书重置失败"
                    proxyOperationError = setup.message
                    return
                }
                setup.requestCertificateSetup()
                dismiss()
            } catch {
                proxyOperationAlertTitle = "证书重置失败"
                proxyOperationError = error.localizedDescription
            }
        }
    }

}
