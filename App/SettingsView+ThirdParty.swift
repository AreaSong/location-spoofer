import SwiftUI
import UIKit

extension SettingsView {
    @ViewBuilder
    var thirdPartyConfigurationSection: some View {
        Section("第三方代理配置") {
            Picker("客户端", selection: Binding(
                get: { thirdPartyClient.selectedClient },
                set: { thirdPartyClient.select($0) }
            )) {
                ForEach(ThirdPartyProxyClient.allCases) { client in
                    Text(client.name).tag(client)
                }
            }

            Text(thirdPartyClient.selectedClient.subscriptionURL.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if moduleSource.distribution == .onDevice {
                Text(moduleServer.isRunning
                     ? "本机模块服务已启动"
                     : (moduleServer.lastError ?? "本机模块服务未启动"))
                    .font(.footnote)
                    .foregroundStyle(moduleServer.isRunning ? Color.secondary : Color.orange)
            }

            if let verificationText = thirdPartyClient.selectedClient.verificationText {
                HStack {
                    Text("验证状态")
                    Spacer()
                    Text(verificationText)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Button {
                ThirdPartyModuleRuntime.prepareForImport()
                UIPasteboard.general.string = thirdPartyClient.selectedClient.subscriptionURL.absoluteString
                copiedClient = thirdPartyClient.selectedClient
            } label: {
                Label(copiedClient == thirdPartyClient.selectedClient ? "已复制模块订阅地址" : "复制模块订阅地址", systemImage: "doc.on.doc")
            }

            Button(action: exportOnDeviceModuleFiles) {
                Label("导出模块文件", systemImage: "square.and.arrow.up")
            }

            Button {
                UIPasteboard.general.string = ThirdPartyProxyManager.interceptionHostnamesText
                copiedMITMHostnames = true
            } label: {
                Label(copiedMITMHostnames ? "已复制解密域名" : "复制解密域名", systemImage: "doc.on.doc")
            }

            Button {
                ThirdPartyModuleRuntime.prepareForImport()
                openThirdPartyClient(thirdPartyClient.selectedClient)
            } label: {
                Label("打开 \(thirdPartyClient.selectedClient.name)", systemImage: "arrow.up.forward.app")
            }

            Button {
                setup.requestThirdPartyOnboarding()
                dismiss()
            } label: {
                Label("重新打开配置引导", systemImage: "arrow.clockwise.circle")
            }

            DisclosureGroup("高级") {
                Picker("模块来源", selection: Binding(
                    get: { moduleSource.distribution },
                    set: { newValue in
                        moduleSource.setDistribution(newValue)
                        ThirdPartyModuleRuntime.syncServerWithDistribution()
                    }
                )) {
                    ForEach(ThirdPartyModuleDistribution.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Text(moduleSourceHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("换来源只影响下次导入，不能替代小火箭拦定位。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if thirdPartyClient.selectedClient == .egern {
                Text("Egern 直接使用 Surge 的 .sgmodule 模块。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if thirdPartyClient.selectedClient == .stash {
                Text("Stash 直接订阅 .stoverride，不要通过 Script Hub 转换。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Text("复制模块订阅地址后，在对应代理客户端中添加模块/重写订阅，并为复制的全部域名（含 gsp-ssl.ls.apple.com、bluedot.is.autonavi.com）启用 MITM。第三方客户端保存坐标后，即使关闭本 App，坐标仍由代理客户端持久化并继续生效。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    var moduleSourceHint: String {
        switch moduleSource.distribution {
        case .onDevice:
            return "默认从本 App 提供模块和脚本，不访问 GitHub。导入或点更新时请保持本 App 打开。"
        case .remoteMirror, .remoteDirect:
            return "仅影响之后复制和重新导入的模块地址；已安装模块需要重新导入后切换来源。"
        }
    }

    func exportOnDeviceModuleFiles() {
        do {
            guard let root = ThirdPartyModuleCatalog.bundledRoot() else {
                throw ThirdPartyModuleCatalogError.bundleMissing
            }
            let urls = try ThirdPartyModuleCatalog.exportOnDeviceFiles(
                moduleFileName: thirdPartyClient.selectedClient.moduleFileName,
                root: root
            )
            ShareSheetPresenter.presentFiles(urls)
        } catch {
            proxyOperationAlertTitle = "导出模块失败"
            proxyOperationError = error.localizedDescription
        }
    }

    var thirdPartyStatusIcon: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "questionmark.circle"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var thirdPartyStatusText: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "未检测"
        case .connected(let active): return active ? "已连接，有坐标" : "已连接，无坐标"
        case .failed: return "连接失败"
        }
    }

    func detectThirdPartyConnection() {
        let client = thirdPartyClient.selectedClient
        let startedAt = Date()
        Task { @MainActor in
            do {
                _ = try await thirdPartyProxy.query()
                RuntimeLogger.info("APP", "ThirdPartyProxy", "设置页第三方连接检测通过", details: [
                    "当前客户端": client.name,
                    "请求动作": "WLOC query",
                    "耗时毫秒": String(Int(Date().timeIntervalSince(startedAt) * 1_000))
                ])
                runtimeMode.markInitialized(.thirdParty)
                runtimeFailure.clearThirdParty()
            } catch {
                RuntimeLogger.error(
                    "APP",
                    "ThirdPartyProxy",
                    "设置页第三方连接检测失败",
                    error: error,
                    details: [
                        "当前客户端": client.name,
                        "请求动作": "WLOC query",
                        "连接状态": String(describing: thirdPartyProxy.connectionState),
                        "耗时毫秒": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                        "原因": ThirdPartyProxyError.diagnosis(for: error).title,
                        "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
                    ]
                )
                presentThirdPartyUnavailable(for: error)
            }
        }
    }

    func openThirdPartyClient(_ client: ThirdPartyProxyClient) {
        guard let url = client.launchURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                proxyOperationAlertTitle = "无法打开客户端"
                proxyOperationError = "无法打开 \(client.name)，请确认客户端已安装后手动打开。"
            }
        }
    }

}
