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
    @ObservedObject var favoriteImport: FavoriteImportCoordinator
    var isSettingsPresented: () -> Bool
    @State var showingBugReport = false
    @State var favoritePageID = UUID()
    @ObservedObject var favorites: FavoriteLocationStore
    var session: SpoofSession
    let proxy = ProxyManager.shared
    @ObservedObject var runtimeMode = ProxyRuntimeModeStore.shared
    let routeLocation = RouteLocationSetupStore.shared
    let thirdPartyProxy = ThirdPartyProxyManager.shared
    let net = NetworkMonitor.shared
    let runtimeFailure = LocationRuntimeFailureStore.shared
    @Environment(\.dismiss) var dismiss
    @State var activeTip: TipKind?
    @State var proxyOperationError = ""
    @State var proxyOperationAlertTitle = "代理操作失败"
    @State var thirdPartyClearRecovery: ThirdPartyModeSwitchRecovery?
    @State var modeOperationRunning = false
    @State var showCertificateResetConfirmation = false
    @State var githubDestination: SafariDestination?
    @State var isCheckingForUpdates = false
    @State var updateCheckResult: UpdateCheckResult?
    @State var mapCoordinateSystemName = CoordinateConverter.MapCoordinateSystem.gcj02.diagnosticName
    @State var mapCoordinateSystemUsedFallback = false
    @State var showFavoriteImporter = false
    @State var showSigningResignSheet = false

    var body: some View {
        settingsPage
    }


    func setProxyOperationAlert(title: String, message: String) {
        proxyOperationAlertTitle = title
        proxyOperationError = message
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


    func refreshMapCoordinateSystemDisplay() {
        mapCoordinateSystemName = CoordinateConverter.currentMapCoordinateSystem.diagnosticName
        mapCoordinateSystemUsedFallback = CoordinateConverter.initialMapCoordinateSystemUsedFallback
    }


    var restoreControlsDisabled: Bool {
        UIPreview.isEnabled()
            || modeOperationRunning
            || actions.state.isBusy
            || (session.state == .verifying && session.writesSuspended)
            || routeLocation.isClearing
    }

    func restoreRealLocation() {
        guard !restoreControlsDisabled else { return }
        session.stop()
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
