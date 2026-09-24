import SwiftUI
import UIKit

struct SetupScreenshotPreview: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

struct CertificateDownloadDestination: Identifiable {
    let id = UUID()
    let url: URL
}

struct ThirdPartyConnectionTestFailure {
    let message: String
}

enum SetupStep: Int, CaseIterable {
    case mode
    case proxy
    case cert
    case thirdPartyClient
    case thirdPartyImport
    case developerTunnel

    var title: String {
        switch self {
        case .mode: return "选择模式"
        case .proxy: return "配置 Wi-Fi 代理"
        case .cert: return "初始化 CA 证书"
        case .thirdPartyClient: return "选择客户端"
        case .thirdPartyImport: return "导入并检测"
        case .developerTunnel: return "连接隧道"
        }
    }
}

struct FirstSetupView: View {
    @ObservedObject var setup: SetupCoordinator
    let onComplete: () -> Void

    @State var step: SetupStep
    @State var downloadedDone = false
    @State var installedDone = false
    @State var trustedDone = false
    @State var result: VerificationResult?
    @State var isVerifying = false
    @State var isPreparingMode = false
    @State var manualHint = ""
    @State var setupActionError = ""
    @State var showDiagnostics = false
    @StateObject var diagnosticActions = LocationActionCoordinator()
    @ObservedObject var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject var routeLocation = RouteLocationSetupStore.shared
    @ObservedObject var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject var moduleSource = ThirdPartyModuleSourceStore.shared
    @ObservedObject var net = NetworkMonitor.shared
    @State var showAppModeNetworkAlert = false
    @State var screenshotPreview: SetupScreenshotPreview?
    @State var certificateDownloadDestination: CertificateDownloadDestination?
    @State var thirdPartyTestFailure: ThirdPartyConnectionTestFailure?
    @State var showThirdPartyRepairReason: Bool
    @State var showsVerificationResult: Bool
    @State var showsThirdPartyFailureLog: Bool

    init(setup: SetupCoordinator, onComplete: @escaping () -> Void) {
        self.setup = setup
        self.onComplete = onComplete
        _step = State(initialValue: setup.setupStep)
        _showThirdPartyRepairReason = State(
            initialValue: setup.setupStep == .thirdPartyImport && !setup.message.isEmpty
        )
        _showsVerificationResult = State(
            initialValue: [.proxy, .cert].contains(setup.setupStep)
                && setup.lastVerificationResult != nil
        )
        _showsThirdPartyFailureLog = State(
            initialValue: setup.setupStep == .thirdPartyImport && !setup.message.isEmpty
        )
    }

    private var diagnosticFavorite: FavoriteLocation {
        FavoriteLocation(name: "诊断位置", latitude: 22.544577, longitude: 113.94114, accuracy: 25)
    }

    var body: some View {
        setupPage
    }

    var setupPage: some View {
        NavigationView {
            VStack(spacing: 0) {
                progress
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch step {
                            case .mode: modeStep
                            case .proxy: proxyStep
                            case .cert: certificateStep
                            case .thirdPartyClient: thirdPartyClientStep
                            case .thirdPartyImport: thirdPartyImportStep
                            case .developerTunnel: developerTunnelStep
                            }
                            if let displayedVerificationResult { resultView(displayedVerificationResult) }
                        }
                        .padding(20)
                    }
                    .onChange(of: thirdPartyFailureLog) { failureLog in
                        guard step == .thirdPartyImport, failureLog != nil else { return }
                        DispatchQueue.main.async {
                            withAnimation {
                                scrollProxy.scrollTo("thirdPartyFailureLog", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: step) { newStep in
                        showsVerificationResult = false
                        showsThirdPartyFailureLog = false
                        if newStep == .thirdPartyImport {
                            ThirdPartyModuleRuntime.prepareForImport()
                        }
                    }
                }
                Divider()
                if step != .mode {
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            Button {
                                returnToPreviousStep()
                            } label: {
                                Label("上一步", systemImage: "chevron.left")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isVerifying || thirdPartyProxy.isRequesting)
                            Spacer(minLength: 12)
                            primaryAction
                        }
                        // “完成”灰着的时候，直接说清楚还差什么。
                        if step == .developerTunnel, let message = routeLocation.readiness.blockingMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("开始使用")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDiagnostics) {
                NavigationView {
                    RuntimeLogsView(
                        setup: setup,
                        actions: diagnosticActions,
                        testFavorite: diagnosticFavorite
                    )
                }
            }
            .sheet(item: $screenshotPreview) { preview in
                NavigationView {
                    ScrollView {
                        Image(uiImage: preview.image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.image))
                            .padding()
                    }
                    .navigationTitle(preview.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { screenshotPreview = nil }
                        }
                    }
                }
            }
            .sheet(item: $certificateDownloadDestination) { destination in
                SafariView(url: destination.url)
                    .ignoresSafeArea()
            }
            .onAppear {
                if step == .thirdPartyImport {
                    ThirdPartyModuleRuntime.prepareForImport()
                }
            }
            .alert(AppModeNetworkRequirement.title, isPresented: $showAppModeNetworkAlert) {
                Button("改用第三方代理模式") {
                    selectMode(.thirdParty)
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(appModeNetworkBlockedMessage ?? "")
            }
            .alert("无法直接跳转", isPresented: Binding(
                get: { !manualHint.isEmpty },
                set: { if !$0 { manualHint = "" } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: { Text(manualHint) }
            .alert("操作失败", isPresented: Binding(
                get: { !setupActionError.isEmpty },
                set: { if !$0 { setupActionError = "" } }
            )) {
                Button("查看诊断日志") { showDiagnostics = true }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(setupActionError)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(visibleSteps, id: \.rawValue) { value in
                HStack(spacing: 6) {
                    Circle()
                        .fill(value.rawValue <= step.rawValue ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(value.title).font(.caption).foregroundStyle(.secondary)
                }
                if value != visibleSteps.last {
                    Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 28, height: 2)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var visibleSteps: [SetupStep] {
        switch step {
        case .mode:
            return [.mode]
        case .proxy, .cert:
            return [.mode, .proxy, .cert]
        case .thirdPartyClient, .thirdPartyImport:
            return [.mode, .thirdPartyClient, .thirdPartyImport]
        case .developerTunnel:
            return [.mode, .developerTunnel]
        }
    }

    private var displayedVerificationResult: VerificationResult? {
        guard showsVerificationResult else { return nil }
        return result ?? setup.lastVerificationResult
    }


    private func returnToPreviousStep() {
        result = nil
        setupActionError = ""
        switch step {
        case .mode:
            break
        case .proxy, .thirdPartyClient:
            step = .mode
        case .cert:
            step = .proxy
        case .thirdPartyImport:
            thirdPartyTestFailure = nil
            step = .thirdPartyClient
        case .developerTunnel:
            step = .mode
        }
    }


    @ViewBuilder
    private func resultView(_ result: VerificationResult) -> some View {
        let success = result.isSuccess
        testResultView(
            success: success,
            title: success ? "环境检测通过" : failureSummary(result),
            log: setup.testLog
        )
    }

    func testResultView(success: Bool, title: String, log: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.subheadline.weight(.semibold))
            if !success {
                Text(log).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
                Button {
                    showDiagnostics = true
                } label: {
                    Label("查看诊断日志", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background((success ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.inset))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if step == .mode {
            EmptyView()
        } else if step == .proxy {
            Button {
                verifyAfterProxyConfirmation()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying)
        } else if step == .cert {
            // 三个勾选只是进度提示；真正的门是下面的环境检测。
            Button {
                verifyAfterCertificateConfirmation()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying)
        } else if step == .developerTunnel {
            Button {
                onComplete()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(routeLocation.readiness != .ready)
        } else if step == .thirdPartyClient {
            Button {
                step = .thirdPartyImport
            } label: {
                actionLabel("完成")
            }
                .buttonStyle(.borderedProminent)
        } else {
            Button {
                verifyThirdPartyConnection()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || thirdPartyProxy.isRequesting)
        }
    }


    private func actionLabel(_ title: String) -> some View {
        HStack {
            if isVerifying { ProgressView().tint(.white).controlSize(.small) }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }


    func runVerification(completion: @escaping (VerificationResult) -> Void) {
        guard !isVerifying else { return }
        isVerifying = true
        result = nil
        showsVerificationResult = false
        Task {
            let verification = await setup.runVerificationTest()
            setup.applyVerificationResult(verification)
            guard !Task.isCancelled else { return }
            result = verification
            showsVerificationResult = true
            isVerifying = false
            completion(verification)
        }
    }

    private func failureSummary(_ result: VerificationResult) -> String {
        switch result {
        case .certNotTrusted: return "证书尚未安装或信任"
        case .wifiProxyNotConfigured: return "Wi-Fi 代理未正确设置"
        case .proxyNotRunning: return "本地代理未能启动"
        case .verificationInProgress: return "检测仍在进行"
        case .verificationSuperseded: return "检测结果已过期"
        case .coordinateWriteFailed: return "坐标写入失败"
        case .patchFailed: return "定位改写检测失败"
        case .success: return "环境检测通过"
        }
    }

}
