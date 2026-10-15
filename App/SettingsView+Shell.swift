import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension SettingsView {
    var settingsPage: some View {
        settingsForm
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshMapCoordinateSystemDisplay()
            if isSettingsPresented(), !showingBugReport { favoriteImport.enterPage(favoritePageID) }
        }
        .onChange(of: showingBugReport) { showing in
            if showing { favoriteImport.leavePage() }
            else if isSettingsPresented() { favoriteImport.enterPage(favoritePageID) }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { closeSettings() } }
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
        .alert(thirdPartyClearRecovery?.alertTitle ?? ThirdPartyModeSwitchRecovery.title, isPresented: Binding(
            get: { thirdPartyClearRecovery != nil },
            set: { if !$0 { thirdPartyClearRecovery = nil } }
        ), presenting: thirdPartyClearRecovery) { recovery in
            if recovery.isLegacyUnverified {
                Button(ThirdPartyModeSwitchRecovery.unusedLegacyTitle) {
                    switchAfterConfirmingUnusedLegacyCoordinates(recovery)
                }
            }
            Button("重试清理") {
                guard recovery.applies(from: runtimeMode.mode, to: recovery.destination) else { return }
                switchRuntimeMode(to: recovery.destination)
            }
            Button(ThirdPartyModeSwitchRecovery.continueTitle) {
                switchRuntimeMode(to: recovery.destination, confirmedThirdPartyDisabled: recovery)
            }
            Button("取消", role: .cancel) {}
        } message: { recovery in
            Text(recovery.message)
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
        .alert(favoriteImport.notice?.title ?? "收藏", isPresented: Binding(
            get: { favoriteImport.notice != nil },
            set: { if !$0 { favoriteImport.notice = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(favoriteImport.notice?.message ?? "")
        }
    }

    var settingsForm: some View {
        Form {
            SettingsRuntimeModeSection(
                actions: actions,
                modeOperationRunning: modeOperationRunning,
                onSelectMode: { switchRuntimeMode(to: $0) }
            )

            SettingsStatusSection(
                actions: actions,
                session: session,
                modeOperationRunning: modeOperationRunning,
                mapCoordinateSystemName: mapCoordinateSystemName,
                mapCoordinateSystemUsedFallback: mapCoordinateSystemUsedFallback,
                showSigningResignSheet: $showSigningResignSheet,
                onRestoreRealLocation: { restoreRealLocation() },
                onDetectThirdParty: { detectThirdPartyConnection() },
                onProxyError: { title, message in
                    setProxyOperationAlert(title: title, message: message)
                }
            )

            if runtimeMode.mode == .developerTunnel {
                RouteLocationSettingsSection(session: session)
            } else if runtimeMode.mode == .thirdParty {
                thirdPartyConfigurationSection
            }

            locationSimulationSection
            favoriteBackupSection

            if runtimeMode.mode != .thirdParty {
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
                NavigationLink(isActive: $showingBugReport) {
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
                            for: ThirdPartyProxyClientStore.shared.selectedClient,
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
        .background(Color(UIColor.systemGroupedBackground))
        .transaction { $0.animation = nil }
    }
}
