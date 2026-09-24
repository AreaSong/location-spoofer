import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension SettingsView {
    var settingsPage: some View {
        Form {
            Section("运行模式") {
                Picker("模式", selection: runtimeModeBinding) {
                    ForEach(ProxyRuntimeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .disabled(modeOperationRunning || actions.state.isBusy || thirdPartyProxy.isRequesting)

                if runtimeMode.mode == .localWiFi, let message = appModeNetworkBlockedMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup("工作原理") {
                    Text(workflowDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }

            Section("状态") {
                if let message = signingExpiryStatus.settingsMessage {
                    let countdown = signingExpiryStatus.expirationDate.flatMap {
                        SigningExpiryCountdown.text(until: $0, now: Date())
                    }
                    Button {
                        showSigningResignSheet = true
                    } label: {
                        Label(countdown ?? message, systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(signingExpiryStatus.isExpired ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if runtimeMode.mode == .localWiFi {
                    HStack {
                        Label("本机代理", systemImage: proxy.isRunning ? "play.circle.fill" : "stop.circle")
                        Spacer()
                        Toggle("", isOn: proxyBinding).labelsHidden()
                            .tint(.blue)
                            .disabled(actions.state.isBusy)
                    }
                } else if runtimeMode.mode == .developerTunnel {
                    HStack {
                        Label("本机隧道", systemImage: "network")
                        Spacer()
                        Text(routeLocation.readiness == .ready ? "已就绪" : "未就绪")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Label("第三方模块", systemImage: thirdPartyStatusIcon)
                        Spacer()
                        Text(thirdPartyStatusText).foregroundStyle(.secondary)
                    }
                    Button {
                        detectThirdPartyConnection()
                    } label: {
                        if thirdPartyProxy.isRequesting {
                            HStack { ProgressView(); Text("正在检测…") }
                        } else {
                            Label("检测连接", systemImage: "network")
                        }
                    }
                    .disabled(thirdPartyProxy.isRequesting)
                }
                HStack {
                    Label("虚拟定位", systemImage: virtualLocationIsActive ? "location.fill" : "location.slash")
                    Spacer()
                    Text(virtualLocationStatusText).foregroundStyle(.secondary)
                }
                HStack {
                    Label("地图坐标标准", systemImage: "globe")
                    Spacer()
                    Text(mapCoordinateSystemName).foregroundStyle(.secondary)
                }
                if mapCoordinateSystemUsedFallback {
                    Text("检测未命中白名单，当前按国内标准显示")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            locationSimulationSection
            if runtimeMode.mode == .developerTunnel {
                RouteLocationSettingsSection()
            }
            favoriteBackupSection

            if runtimeMode.mode == .thirdParty {
                thirdPartyConfigurationSection
            } else {
                Section("说明") {
                    Button {
                        activeTip = .activation
                    } label: {
                        Label("生效说明", systemImage: "checklist")
                    }
                    Button {
                        activeTip = .deactivation
                    } label: {
                        Label("失效说明", systemImage: "arrow.uturn.backward.circle")
                    }
                    if runtimeMode.mode == .localWiFi {
                        Button {
                            activeTip = .removeProxy
                        } label: {
                            Label("关闭 WiFi 代理", systemImage: "wifi.slash")
                        }
                    }
                }

            }

            Section("应用") {
                if runtimeMode.mode == .localWiFi {
                    Button {
                        setup.requestSetup()
                    } label: {
                        Label("进入引导页", systemImage: "arrow.clockwise.circle")
                    }
                } else if runtimeMode.mode == .developerTunnel {
                    Button {
                        setup.requestDeveloperOnboarding()
                        dismiss()
                    } label: {
                        Label("进入引导页", systemImage: "arrow.clockwise.circle")
                    }
                }
                Button {
                    checkForUpdates()
                } label: {
                    if isCheckingForUpdates {
                        HStack {
                            ProgressView()
                            Text("正在检查…")
                        }
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isCheckingForUpdates)
                valueRow("版本", value: versionText)
            }

            if runtimeMode.mode == .localWiFi {
                Section("证书") {
                    Button(role: .destructive) {
                        showCertificateResetConfirmation = true
                    } label: {
                        Label("重置证书", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(modeOperationRunning || actions.state.isBusy)

                    Text("仅删除 App 钥匙串中的设备 CA。iOS 中已经安装的旧证书需要在系统设置里手动移除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("支持") {
                NavigationLink {
                    BugReportView(setup: setup)
                } label: {
                    Label("报告 Bug", systemImage: "ladybug")
                }

                Button {
                    githubDestination = SafariDestination(url: GitHubSubmission.usageHelpURL)
                } label: {
                    Label("使用帮助", systemImage: "questionmark.circle")
                }

                Button {
                    githubDestination = SafariDestination(url: GitHubSubmission.featureRequestURL)
                } label: {
                    Label("功能建议", systemImage: "lightbulb")
                }

                if runtimeMode.mode == .thirdParty {
                    Button {
                        UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                            for: thirdPartyClient.selectedClient,
                            systemVersion: UIDevice.current.systemVersion
                        )
                        githubDestination = SafariDestination(
                            url: GitHubSubmission.communityContributionURL
                        )
                    } label: {
                        Label("分享第三方配置", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("关于") {
                Button {
                    if let url = URL(string: "https://github.com/AreaSong/location-spoofer") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("AreaSong/location-spoofer", systemImage: "link")
                }
                Text("如果觉得好用，欢迎去 GitHub 给项目点个 Star")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: "https://github.com/Yu9191/wloc") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("核心定位改写逻辑移植自 Yu9191/wloc", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }
                Text("原仓库已失效，模块已内置，请勿再去找订阅地址。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshMapCoordinateSystemDisplay)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
        }
        .sheet(item: $activeTip) { kind in
            TipSheetView(kind: kind)
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showSigningResignSheet) {
            SigningResignGuideView()
        }
        .alert(proxyOperationAlertTitle, isPresented: Binding(
            get: { !proxyOperationError.isEmpty },
            set: { if !$0 { proxyOperationError = "" } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(proxyOperationError)
        }
        .alert(item: $updateCheckResult) { result in
            updateCheckAlert(for: result)
        }
        .confirmationDialog(
            "重置证书？",
            isPresented: $showCertificateResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重置并生成新证书", role: .destructive) {
                resetCertificateAuthority()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前虚拟定位和本地代理将停止。App 会删除钥匙串中的设备 CA、立即生成新证书，并打开安装与信任引导。你还需要前往 iOS「设置 → 通用 → VPN 与设备管理」手动删除旧证书，然后重新下载安装并完全信任新证书。")
        }
        .fileImporter(isPresented: $showFavoriteImporter, allowedContentTypes: [.json]) { result in
            importFavorites(from: result)
        }
        .alert(favoriteTransferTitle, isPresented: Binding(
            get: { !favoriteTransferMessage.isEmpty },
            set: { if !$0 { favoriteTransferMessage = "" } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(favoriteTransferMessage)
        }
    }
}
