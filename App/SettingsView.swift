import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum UpdateCheckResult: Identifiable {
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
    @ObservedObject var proxy = ProxyManager.shared
    @ObservedObject var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject var routeLocation = RouteLocationSetupStore.shared
    @ObservedObject var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject var motionSimulation = MotionSimulationStore.shared
    @ObservedObject var randomRadius = RandomRadiusStore.shared
    @ObservedObject var locationAccuracy = LocationAccuracyStore.shared
    @ObservedObject var moduleSource = ThirdPartyModuleSourceStore.shared
    @ObservedObject var moduleServer = ThirdPartyModuleServer.shared
    @ObservedObject var net = NetworkMonitor.shared
    @ObservedObject var runtimeFailure = LocationRuntimeFailureStore.shared
    @Environment(\.dismiss) var dismiss
    @State var activeTip: TipKind?
    @State var proxyOperationError = ""
    @State var proxyOperationAlertTitle = "代理操作失败"
    @State var modeOperationRunning = false
    @State var copiedClient: ThirdPartyProxyClient?
    @State var copiedMITMHostnames = false
    @State var showCertificateResetConfirmation = false
    @State var githubDestination: SafariDestination?
    @State var isCheckingForUpdates = false
    @State var updateCheckResult: UpdateCheckResult?
    @State var mapCoordinateSystemName = CoordinateConverter.MapCoordinateSystem.gcj02.diagnosticName
    @State var mapCoordinateSystemUsedFallback = false
    @State var copiedFavorites = false
    @State var showFavoriteImporter = false
    @State var favoriteTransferTitle = "收藏"
    @State var favoriteTransferMessage = ""
    @State var showSigningResignSheet = false

    var body: some View {
        settingsPage
    }


    func valueRow(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).font(.footnote.monospaced()).foregroundStyle(.secondary) }
    }

    var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    func checkForUpdates() {
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

    func updateCheckAlert(for result: UpdateCheckResult) -> Alert {
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


    var runtimeModeBinding: Binding<ProxyRuntimeMode> {
        Binding(
            get: { runtimeMode.mode },
            set: { newMode in switchRuntimeMode(to: newMode) }
        )
    }


    func refreshMapCoordinateSystemDisplay() {
        mapCoordinateSystemName = CoordinateConverter.currentMapCoordinateSystem.diagnosticName
        mapCoordinateSystemUsedFallback = CoordinateConverter.initialMapCoordinateSystemUsedFallback
    }


    var virtualLocationStatusText: String {
        if runtimeMode.mode == .developerTunnel {
            return routeLocation.isSimulating ? "已开启" : "已关闭"
        }
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled ? "已开启" : "已关闭"
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active ? "第三方已保存" : "未保存"
        }
        return "未知"
    }

    var workflowDescription: String {
        if runtimeMode.mode == .developerTunnel {
            return "定点和路线都通过 LocalDevVPN 的本机隧道推进系统定位。不启动本机代理，也不使用小火箭模块。需要隧道已连接，并已导入配对文件。"
        }
        if runtimeMode.mode == .thirdParty {
            return "App 只负责地图选点、收藏和发送 WGS-84 坐标。第三方代理客户端通过模块拦截 Apple WLOC 请求并持久化当前坐标；本模式不启动本机代理，不使用 App 的 CA，也不需要配置 127.0.0.1:8888。"
        }
        return """
        App 在设备本地运行一个代理服务器（127.0.0.1:8888）。

        通过 WiFi 手动代理配置，让系统发往 Apple 定位域名（gs-loc.apple.com、gsp-ssl.ls.apple.com、bluedot.is.autonavi.com 等）的定位请求经过这个本地代理。代理使用已安装的 CA 证书对 HTTPS 流量做中间人解密，把 Apple 返回的定位坐标改写为你设置的虚拟坐标，再加密返回给系统，从而实现虚拟定位。
        """
    }


    var signingExpiryStatus: SigningExpiryStatus {
        SigningExpiry.current()
    }


    var virtualLocationIsActive: Bool {
        if runtimeMode.mode == .developerTunnel {
            return routeLocation.isSimulating
        }
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active
        }
        return false
    }
}

enum ShareSheetPresenter {
    static func presentFile(at url: URL) {
        presentFiles([url])
    }

    static func presentFiles(_ urls: [URL]) {
        guard let presenter = topViewController() else { return }
        presenter.present(UIActivityViewController(activityItems: urls, applicationActivities: nil), animated: true)
    }

    static func topViewController() -> UIViewController? {
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
