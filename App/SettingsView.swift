import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum UpdateCheckResult: Identifiable {
    case current(currentVersion: String, latestVersion: String)
    case available(AppUpdatePrompt)
    case failed

    var id: String {
        switch self {
        case .current(let currentVersion, let latestVersion):
            return "current-\(currentVersion)-\(latestVersion)"
        case .available(let prompt):
            return "available-\(prompt.id)"
        case .failed:
            return "failed"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var setup: SetupCoordinator
    @ObservedObject var actions: LocationActionCoordinator
    @ObservedObject var favorites: FavoriteLocationStore
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject private var motionSimulation = MotionSimulationStore.shared
    @ObservedObject private var randomRadius = RandomRadiusStore.shared
    @ObservedObject private var locationAccuracy = LocationAccuracyStore.shared
    @ObservedObject private var moduleSource = ThirdPartyModuleSourceStore.shared
    @ObservedObject private var moduleServer = ThirdPartyModuleServer.shared
    @ObservedObject private var net = NetworkMonitor.shared
    @ObservedObject private var runtimeFailure = LocationRuntimeFailureStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var activeTip: TipKind?
    @State private var proxyOperationError = ""
    @State private var proxyOperationAlertTitle = "代理操作失败"
    @State private var modeOperationRunning = false
    @State private var copiedClient: ThirdPartyProxyClient?
    @State private var copiedMITMHostnames = false
    @State private var showCertificateResetConfirmation = false
    @State private var githubDestination: SafariDestination?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckResult: UpdateCheckResult?
    @State private var mapCoordinateSystemName = CoordinateConverter.MapCoordinateSystem.gcj02.diagnosticName
    @State private var mapCoordinateSystemUsedFallback = false
    @State private var copiedFavorites = false
    @State private var showFavoriteImporter = false
    @State private var favoriteTransferTitle = "收藏"
    @State private var favoriteTransferMessage = ""
    @State private var showSigningResignSheet = false

    var body: some View {
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
            }

            Section("状态") {
                if let message = signingExpiryStatus.settingsMessage {
                    Button {
                        showSigningResignSheet = true
                    } label: {
                        Label(message, systemImage: "calendar.badge.exclamationmark")
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
                    Button {
                        activeTip = .removeProxy
                    } label: {
                        Label("关闭 WiFi 代理", systemImage: "wifi.slash")
                    }
                }

            }

            Section("工作原理") {
                Text(workflowDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("应用") {
                if runtimeMode.mode == .localWiFi {
                    Button {
                        setup.requestSetup()
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
                    if let url = URL(string: "https://github.com/xweiba/location-spoofer") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("xweiba/location-spoofer", systemImage: "link")
                }
                Text("如果觉得好用，欢迎去 GitHub 给项目点个 Star")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("致谢") {
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

    private func valueRow(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).font(.footnote.monospaced()).foregroundStyle(.secondary) }
    }

    private var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task { @MainActor in
            defer { isCheckingForUpdates = false }
            guard let configuration = await AppRemoteConfigurationService.fetch() else {
                updateCheckResult = .failed
                return
            }
            AppRemoteConfigurationStore.shared.apply(configuration)
            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? AppRemoteConfiguration.fallback.latestVersion
            guard let pendingPrompt = configuration.updatePrompt(currentVersion: currentVersion) else {
                updateCheckResult = .current(
                    currentVersion: currentVersion,
                    latestVersion: configuration.latestVersion
                )
                return
            }
            let releaseNotes = await AppRemoteConfigurationService.fetchReleaseNotes(
                version: pendingPrompt.latestVersion
            )
            let prompt = configuration.updatePrompt(
                currentVersion: currentVersion,
                releaseNotes: releaseNotes
            ) ?? pendingPrompt
            updateCheckResult = .available(prompt)
        }
    }

    private func updateCheckAlert(for result: UpdateCheckResult) -> Alert {
        switch result {
        case .current(let currentVersion, let latestVersion):
            return Alert(
                title: Text("已是最新版本"),
                message: Text("当前版本 \(currentVersion)，远程最新版本 \(latestVersion)。"),
                dismissButton: .default(Text("知道了"))
            )
        case .available(let prompt):
            let details = prompt.releaseNotes
                ?? "更新说明暂时无法加载，请前往最新 Release 页面查看。"
            let message: String
            if prompt.requirement == .required {
                message = "当前版本 \(prompt.currentVersion) 已停止支持，请更新到 \(prompt.latestVersion) 后继续使用。\n\n\(details)"
            } else {
                message = "当前版本 \(prompt.currentVersion)，最新版本 \(prompt.latestVersion)。\n\n\(details)"
            }
            return Alert(
                title: Text(prompt.requirement == .required ? "需要更新" : "发现新版本"),
                message: Text(message),
                primaryButton: .default(Text("前往更新")) {
                    UIApplication.shared.open(AppRemoteConfigurationService.releasesURL)
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        case .failed:
            return Alert(
                title: Text("检查更新失败"),
                message: Text("无法获取远程版本信息，请检查网络后重试。"),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var proxyBinding: Binding<Bool> {
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

    private var runtimeModeBinding: Binding<ProxyRuntimeMode> {
        Binding(
            get: { runtimeMode.mode },
            set: { newMode in switchRuntimeMode(to: newMode) }
        )
    }

    private var motionSimulationBinding: Binding<Bool> {
        Binding(
            get: { motionSimulation.isEnabled },
            set: { enabled in
                proxy.applyMotionSimulation(enabled)
            }
        )
    }

    private var simulationControlsDisabled: Bool {
        modeOperationRunning || actions.state.isBusy || thirdPartyProxy.isRequesting
    }

    @ViewBuilder
    private var locationSimulationSection: some View {
        Section("定位模拟") {
            if runtimeMode.mode == .localWiFi {
                Toggle("运动状态模拟", isOn: motionSimulationBinding)
                    .disabled(simulationControlsDisabled)
                Text("实验性功能，默认关闭。开启后会同时模拟定位响应中的运动状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("随机扰动", isOn: randomRadiusBinding)
                .disabled(simulationControlsDisabled)
            if randomRadius.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("扰动半径 \(Int(randomRadius.radius.rounded())) 米")
                    Slider(
                        value: randomRadiusMetersBinding,
                        in: RandomRadiusStore.minimumMeters...RandomRadiusStore.maximumMeters,
                        step: 10
                    )
                    .disabled(simulationControlsDisabled)
                }
            }
            Text(randomRadiusHint)
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("定位精度 \(locationAccuracy.meters) 米")
                Slider(
                    value: accuracyMetersBinding,
                    in: Double(LocationAccuracyStore.minimumMeters)...Double(LocationAccuracyStore.maximumMeters),
                    step: 5
                )
                .disabled(simulationControlsDisabled)
            }
            Text("写入定位响应的精度字段。数值越小，系统越倾向认为位置可靠。下次同步或开启时生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var randomRadiusHint: String {
        runtimeMode.mode == .thirdParty
            ? "开启后，下次同步坐标时会给目标点添加随机偏移，避免位置固定在同一点。"
            : "开启后，下次开启虚拟定位时会给目标点添加随机偏移，避免位置固定在同一点。"
    }

    private var randomRadiusBinding: Binding<Bool> {
        Binding(
            get: { randomRadius.isEnabled },
            set: { randomRadius.setEnabled($0) }
        )
    }

    private var randomRadiusMetersBinding: Binding<Double> {
        Binding(
            get: { randomRadius.radius },
            set: { randomRadius.setRadius($0) }
        )
    }

    private var accuracyMetersBinding: Binding<Double> {
        Binding(
            get: { Double(locationAccuracy.meters) },
            set: { locationAccuracy.setMeters(Int($0.rounded())) }
        )
    }

    @ViewBuilder
    private var favoriteBackupSection: some View {
        Section("收藏") {
            Text("共 \(favorites.favorites.count) 个地点。导入时相同国际坐标会更新名称，新地点会追加。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: exportFavoritesToClipboard) {
                Label(copiedFavorites ? "已复制收藏备份" : "导出到剪贴板", systemImage: "doc.on.doc")
            }
            .disabled(favorites.favorites.isEmpty)
            Button(action: shareFavoritesFile) {
                Label("分享备份文件", systemImage: "square.and.arrow.up")
            }
            .disabled(favorites.favorites.isEmpty)
            Button(action: importFavoritesFromClipboard) {
                Label("从剪贴板导入", systemImage: "clipboard")
            }
            Button {
                showFavoriteImporter = true
            } label: {
                Label("从文件导入", systemImage: "folder")
            }
        }
    }

    private func refreshMapCoordinateSystemDisplay() {
        mapCoordinateSystemName = CoordinateConverter.currentMapCoordinateSystem.diagnosticName
        mapCoordinateSystemUsedFallback = CoordinateConverter.initialMapCoordinateSystemUsedFallback
    }

    private func exportFavoritesToClipboard() {
        do {
            let data = try favorites.exportTransferred()
            guard let text = String(data: data, encoding: .utf8) else {
                presentFavoriteTransferError("无法编码收藏备份")
                return
            }
            UIPasteboard.general.string = text
            copiedFavorites = true
            RuntimeLogger.info("APP", "收藏", "已导出收藏到剪贴板", details: [
                "数量": String(favorites.favorites.count)
            ])
        } catch {
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    private func shareFavoritesFile() {
        do {
            let data = try favorites.exportTransferred()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("location-spoofer-favorites.json")
            try data.write(to: url, options: .atomic)
            ShareSheetPresenter.presentFile(at: url)
        } catch {
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    private func importFavoritesFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentFavoriteTransferError("剪贴板里没有收藏备份")
            return
        }
        importFavorites(from: Data(text.utf8))
    }

    private func importFavorites(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                importFavorites(from: try Data(contentsOf: url))
            } catch {
                presentFavoriteTransferError(error.localizedDescription)
            }
        case .failure(let error):
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    private func importFavorites(from data: Data) {
        do {
            let incoming = try FavoriteTransfer.decode(data)
            let result = favorites.importTransferred(incoming)
            favoriteTransferTitle = "收藏已导入"
            favoriteTransferMessage = "新增 \(result.added) 个，更新 \(result.updated) 个"
            RuntimeLogger.info("APP", "收藏", "已合并导入收藏", details: [
                "新增": String(result.added),
                "更新": String(result.updated)
            ])
        } catch {
            presentFavoriteTransferError(error.localizedDescription)
        }
    }

    private func presentFavoriteTransferError(_ message: String) {
        favoriteTransferTitle = "收藏导入失败"
        favoriteTransferMessage = message
    }

    @ViewBuilder
    private var thirdPartyConfigurationSection: some View {
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

    private var moduleSourceHint: String {
        switch moduleSource.distribution {
        case .onDevice:
            return "默认从本 App 提供模块和脚本，不访问 GitHub。导入或点更新时请保持本 App 打开。"
        case .remoteMirror, .remoteDirect:
            return "仅影响之后复制和重新导入的模块地址；已安装模块需要重新导入后切换来源。"
        }
    }

    private func exportOnDeviceModuleFiles() {
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

    private var thirdPartyStatusIcon: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "questionmark.circle"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var thirdPartyStatusText: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "未检测"
        case .connected(let active): return active ? "已连接，有坐标" : "已连接，无坐标"
        case .failed: return "连接失败"
        }
    }

    private var virtualLocationStatusText: String {
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled ? "已开启" : "已关闭"
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active ? "第三方已保存" : "未保存"
        }
        return "未知"
    }

    private var workflowDescription: String {
        if runtimeMode.mode == .thirdParty {
            return "App 只负责地图选点、收藏和发送 WGS-84 坐标。第三方代理客户端通过模块拦截 Apple WLOC 请求并持久化当前坐标；本模式不启动本机代理，不使用 App 的 CA，也不需要配置 127.0.0.1:8888。"
        }
        return """
        App 在设备本地运行一个代理服务器（127.0.0.1:8888）。

        通过 WiFi 手动代理配置，让系统发往 Apple 定位域名（gs-loc.apple.com、gsp-ssl.ls.apple.com、bluedot.is.autonavi.com 等）的定位请求经过这个本地代理。代理使用已安装的 CA 证书对 HTTPS 流量做中间人解密，把 Apple 返回的定位坐标改写为你设置的虚拟坐标，再加密返回给系统，从而实现虚拟定位。
        """
    }

    private var appModeNetworkBlockedMessage: String? {
        AppModeNetworkRequirement.blockedMessage(
            wifiEnabled: net.isWiFiEnabled,
            cellularEnabled: net.usesCellular
        )
    }

    private var signingExpiryStatus: SigningExpiryStatus {
        SigningExpiry.current()
    }

    private func switchRuntimeMode(to newMode: ProxyRuntimeMode) {
        guard newMode != runtimeMode.mode, !modeOperationRunning else { return }
        if newMode == .localWiFi, let message = appModeNetworkBlockedMessage {
            proxyOperationAlertTitle = AppModeNetworkRequirement.title
            proxyOperationError = message
            return
        }
        modeOperationRunning = true
        Task { @MainActor in
            defer { modeOperationRunning = false }
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
            case .localWiFi:
                ThirdPartyModuleRuntime.shutdown()
                do {
                    try await thirdPartyProxy.clear()
                } catch {
                    RuntimeLogger.warning("APP", "Mode", "切换 APP 模式前无法清除第三方坐标", details: [
                        "错误": error.localizedDescription
                    ])
                }
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

    private func detectThirdPartyConnection() {
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

    private func presentThirdPartyUnavailable(for error: Error) {
        runtimeFailure.recordThirdParty(error: error)
        proxyOperationAlertTitle = LocationUseBlock.title
        proxyOperationError = ThirdPartyProxyError.diagnosis(for: error).summary
    }

    private func resetCertificateAuthority() {
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

    private func openThirdPartyClient(_ client: ThirdPartyProxyClient) {
        guard let url = client.launchURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                proxyOperationAlertTitle = "无法打开客户端"
                proxyOperationError = "无法打开 \(client.name)，请确认客户端已安装后手动打开。"
            }
        }
    }

    private var virtualLocationIsActive: Bool {
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active
        }
        return false
    }
}

private enum ShareSheetPresenter {
    static func presentFile(at url: URL) {
        presentFiles([url])
    }

    static func presentFiles(_ urls: [URL]) {
        guard let presenter = topViewController() else { return }
        presenter.present(UIActivityViewController(activityItems: urls, applicationActivities: nil), animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
