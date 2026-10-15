import SwiftUI

/// 运行模式和状态各自观察自己的 Store，避免隧道轮询或网络快照把整页 Form 重绘一遍。
struct SettingsRuntimeModeSection: View {
    @ObservedObject var actions: LocationActionCoordinator
    var modeOperationRunning: Bool
    var onSelectMode: (ProxyRuntimeMode) -> Void

    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var routeLocation = RouteLocationSetupStore.shared
    @ObservedObject private var net = NetworkMonitor.shared

    var body: some View {
        Section("运行模式") {
            Picker("模式", selection: modeBinding) {
                ForEach(ProxyRuntimeMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.displayName)
                            .font(.body)
                        Text(mode.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(modeOperationRunning || actions.state.isBusy || routeLocation.isClearing)

            if runtimeMode.mode == .localWiFi, let message = AppModeNetworkRequirement.blockedMessage(net.appModeNetworkStatus) {
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
    }

    private var modeBinding: Binding<ProxyRuntimeMode> {
        Binding(
            get: { runtimeMode.mode },
            set: onSelectMode
        )
    }

    private var workflowDescription: String {
        if runtimeMode.mode == .developerTunnel {
            return "定点和路线都通过本机隧道推进系统定位，不拦截网络请求。不启动本机代理，也不使用小火箭模块。隧道由 LocalDevVPN 建立，需要隧道已连接，并已导入配对文件。"
        }
        if runtimeMode.mode == .thirdParty {
            return "App 只负责地图选点、收藏和发送 WGS-84 坐标。第三方代理客户端通过模块拦截 Apple WLOC 请求并持久化当前坐标；本模式不启动本机代理，不使用 App 的 CA，也不需要配置 127.0.0.1:8888。"
        }
        return """
        App 在设备本地运行一个代理服务器（127.0.0.1:8888）。

        通过 WiFi 手动代理配置，让系统发往 Apple 定位域名（gs-loc.apple.com、gsp-ssl.ls.apple.com、bluedot.is.autonavi.com 等）的定位请求经过这个本地代理。代理使用已安装的 CA 证书对 HTTPS 流量做中间人解密，把 Apple 返回的定位坐标改写为你设置的虚拟坐标，再加密返回给系统，从而实现虚拟定位。
        """
    }
}

struct SettingsStatusSection: View {
    @ObservedObject var actions: LocationActionCoordinator
    @ObservedObject var session: SpoofSession
    var modeOperationRunning: Bool
    var mapCoordinateSystemName: String
    var mapCoordinateSystemUsedFallback: Bool
    @Binding var showSigningResignSheet: Bool
    var onRestoreRealLocation: () -> Void
    var onDetectThirdParty: () -> Void
    var onProxyError: (String, String) -> Void

    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var routeLocation = RouteLocationSetupStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared

    var body: some View {
        Section("状态") {
            if UIPreview.isEnabled() {
                Text("当前是开发者模式，下面的成功状态不会写入正常使用。换成一种运行模式后，下次启动进入真实引导。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            signingExpiryRow
            runtimeServiceRow
            virtualLocationRow
            if runtimeMode.mode != .developerTunnel {
                Button(action: onRestoreRealLocation) {
                    Label("恢复真实定位", systemImage: "location.slash")
                }
                .disabled(restoreControlsDisabled)
                Text("关掉当前虚拟定位，让系统回到真实位置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label {
                    Text("地图坐标标准")
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text(mapCoordinateSystemName).foregroundStyle(.secondary)
            }
            if mapCoordinateSystemUsedFallback {
                Text("当前位于国内服务区，已自动按国内标准对齐显示")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var signingExpiryRow: some View {
        if signingExpiryStatus.settingsMessage != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let status = SigningExpiry.current(now: context.date)
                if let message = status.settingsMessage {
                    let countdown = status.expirationDate.flatMap {
                        SigningExpiryCountdown.text(until: $0, now: context.date)
                    }
                    Button {
                        showSigningResignSheet = true
                    } label: {
                        Label(countdown ?? message, systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(status.isExpired ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var runtimeServiceRow: some View {
        if runtimeMode.mode == .localWiFi {
            HStack {
                Label {
                    Text("本机代理")
                } icon: {
                    Image(systemName: proxy.isRunning ? "play.circle.fill" : "stop.circle")
                        .foregroundStyle(proxy.isRunning ? Color.green : Color.secondary)
                }
                Spacer()
                Toggle("", isOn: proxyBinding).labelsHidden()
                    .tint(.blue)
                    .disabled(actions.state.isBusy || UIPreview.isEnabled())
            }
        } else if runtimeMode.mode == .developerTunnel {
            HStack {
                Label {
                    Text("本机隧道")
                } icon: {
                    Image(systemName: "network")
                        .foregroundStyle(routeLocation.readiness == .ready ? Color.green : Color.orange)
                }
                Spacer()
                Text(routeLocation.readiness == .ready ? "已就绪" : "未就绪")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(routeLocation.readiness == .ready ? Color.green : Color.orange)
            }
        } else {
            thirdPartyRuntimeRow
        }
    }

    @ViewBuilder
    private var thirdPartyRuntimeRow: some View {
        HStack {
            Label {
                Text("第三方模块")
            } icon: {
                Image(systemName: thirdPartyStatusIcon)
                    .foregroundStyle(thirdPartyStatusColor)
            }
            Spacer()
            Text(thirdPartyStatusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(thirdPartyStatusColor)
        }
        Button(action: onDetectThirdParty) {
            if thirdPartyProxy.isRequesting {
                HStack { ProgressView(); Text("正在检测…") }
            } else {
                Label("检测连接", systemImage: "network")
            }
        }
        .disabled(thirdPartyProxy.isRequesting || UIPreview.isEnabled())
        thirdPartyReadback
    }

    private var virtualLocationRow: some View {
        HStack {
            Label {
                Text("虚拟定位")
            } icon: {
                Image(systemName: virtualLocationIsActive ? "location.fill" : "location.slash")
                    .foregroundStyle(virtualLocationIsActive ? Color.blue : Color.secondary)
            }
            Spacer()
            Text(virtualLocationStatusText)
                .font(.subheadline.weight(virtualLocationIsActive ? .semibold : .regular))
                .foregroundStyle(virtualLocationIsActive ? Color.blue : Color.secondary)
        }
    }

    private var signingExpiryStatus: SigningExpiryStatus {
        SigningExpiry.current()
    }

    private var restoreControlsDisabled: Bool {
        UIPreview.isEnabled()
            || modeOperationRunning
            || actions.state.isBusy
            || (session.state == .verifying && session.writesSuspended)
            || routeLocation.isClearing
    }

    private var virtualLocationIsActive: Bool {
        if runtimeMode.mode == .developerTunnel {
            return routeLocation.isSimulating || routeLocation.activity.simulationMayStillBeActive
        }
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active
        }
        return false
    }

    private var virtualLocationStatusText: String {
        if runtimeMode.mode == .developerTunnel {
            return routeLocation.simulationStatusText
        }
        if runtimeMode.mode == .localWiFi {
            return actions.virtualLocationEnabled ? "已开启" : "已关闭"
        }
        if case .connected(let active) = thirdPartyProxy.connectionState {
            return active ? "第三方已保存" : "未保存"
        }
        return "未知"
    }

    private var thirdPartyStatusIcon: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "questionmark.circle"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var thirdPartyStatusColor: Color {
        switch thirdPartyProxy.connectionState {
        case .unknown: return .secondary
        case .connected(let active): return active ? .green : .blue
        case .failed: return .red
        }
    }

    private var thirdPartyStatusText: String {
        switch thirdPartyProxy.connectionState {
        case .unknown: return "未检测"
        case .connected(let active): return active ? "已连接，有坐标" : "已连接，无坐标"
        case .failed: return "连接失败"
        }
    }

    private var thirdPartyReadback: some View {
        let settings = thirdPartyProxy.activeSettings
        return VStack(alignment: .leading, spacing: 4) {
            Text("模块版本 \(settings?.reportedVersion ?? "未回报")")
            Text("回读坐标 \(settings?.readbackCoordinateText ?? "未回报")")
            Text("设定半径 \(settings?.configuredRadiusText ?? "未回报")")
            Text("实际偏移 \(settings?.appliedOffsetText ?? "未回报")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var proxyBinding: Binding<Bool> {
        Binding(get: { proxy.isRunning }, set: { on in
            Task {
                if on {
                    do {
                        try await proxy.start()
                    } catch {
                        proxy.error = error.localizedDescription
                        onProxyError("代理操作失败", error.localizedDescription)
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
}
