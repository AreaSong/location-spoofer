import SwiftUI

extension FirstSetupView {
    private struct ModeCardContent {
        let title: String
        let icon: String
        let badges: [String]
        let description: String
        let tint: Color
    }

    var currentIOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    var modeStep: some View {
        let iOSMajor = currentIOSMajorVersion
        return VStack(alignment: .leading, spacing: 16) {
            Text("选择运行模式")
                .font(.title2.bold())
            Text("已按当前系统版本排好顺序，推荐的排在最前。后续可在“设置 → 运行模式”中切换。APP 模式和第三方模式不要同时拦截定位响应。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if iOSMajor >= RuntimeModeAvailability.mitmBlockedMajorVersion {
                thirdPartyMITMWarning
            }

            if let message = appModeNetworkBlockedMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(RuntimeModeAvailability.orderedModes(iOSMajor: iOSMajor)) { mode in
                modeCard(for: mode, status: RuntimeModeAvailability.status(for: mode, iOSMajor: iOSMajor))
                    .disabled(isPreparingMode)
            }

            if isPreparingMode {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在准备 APP模式本地服务…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            if UIPreview.isAvailable {
                Button(action: onPreview) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("只看界面")
                            .font(.headline)
                        Text("打开地图看定点、走路和底栏。开始和走路不会改系统定位。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isPreparingMode)
            }
        }
    }

    private func modeCardContent(for mode: ProxyRuntimeMode) -> ModeCardContent {
        switch mode {
        case .localWiFi:
            return ModeCardContent(
                title: "APP模式",
                icon: "iphone.and.arrow.forward",
                badges: ["仅 Wi-Fi", "无外部依赖"],
                description: "App 在设备本地启动代理，通过当前 Wi-Fi 的手动 HTTP 代理改写定位响应。免费自签应用无法使用系统 VPN 的 Network Extension 能力，因此 APP模式不支持蜂窝网络，需要配置 Wi-Fi 代理并安装 App 生成的 CA。",
                tint: .blue
            )
        case .developerTunnel:
            return ModeCardContent(
                title: "开发者隧道模式",
                icon: "location.fill.viewfinder",
                badges: ["定点 + 路线", "系统定位", "iOS 18+"],
                description: "通过本机隧道把坐标推进系统定位，不拦截网络请求。定点会停在图钉上，路线会跟着走。需要安装 LocalDevVPN 建立隧道，并用电脑生成一次配对文件。",
                tint: .green
            )
        case .thirdParty:
            return ModeCardContent(
                title: "第三方代理模式",
                icon: "network.badge.shield.half.filled",
                badges: ["Wi-Fi + 4G/5G", "测试模式"],
                description: "App 负责选点，并通过 WLOC 配置接口查询和同步坐标；第三方代理客户端负责网络代理、模块拦截、MITM 和持久化。证书、VPN 与代理连接均由第三方客户端处理。",
                tint: .orange
            )
        }
    }

    private func modeCard(for mode: ProxyRuntimeMode, status: RuntimeModeAvailability.Status) -> some View {
        let content = modeCardContent(for: mode)
        let isRecommended = status == .recommended
        var isUnavailable = false
        if case .unavailable = status { isUnavailable = true }
        return Button {
            selectMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label(content.title, systemImage: content.icon)
                        .font(.headline)
                        .foregroundStyle(content.tint)
                    if isRecommended {
                        Text("推荐")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(content.tint, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    ForEach(content.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(content.tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(content.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                switch status {
                case .limited(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                case .unavailable(let reason):
                    Label(reason, systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                case .recommended, .available:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: AppRadius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.control)
                    .stroke(content.tint.opacity(isRecommended ? 0.6 : 0.25), lineWidth: isRecommended ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable)
        .opacity(isUnavailable ? 0.55 : 1)
        .accessibilityLabel(isRecommended ? "\(content.title)，推荐" : content.title)
    }

    var appModeNetworkBlockedMessage: String? {
        AppModeNetworkRequirement.blockedMessage(
            wifiEnabled: net.isWiFiEnabled,
            cellularEnabled: net.usesCellular
        )
    }

    func selectMode(_ mode: ProxyRuntimeMode) {
        guard !isPreparingMode else { return }
        if mode == .localWiFi, appModeNetworkBlockedMessage != nil {
            showAppModeNetworkAlert = true
            return
        }
        runtimeMode.setMode(mode)
        result = nil
        switch mode {
        case .localWiFi:
            isPreparingMode = true
            ThirdPartyModuleRuntime.shutdown()
            Task { @MainActor in
                await setup.prepareLocalServices()
                isPreparingMode = false
                step = .proxy
            }
        case .thirdParty:
            setup.proxy.stop()
            BackgroundKeepAlive.shared.stop()
            ThirdPartyModuleRuntime.syncServerWithDistribution()
            step = .thirdPartyClient
        case .developerTunnel:
            setup.proxy.stop()
            BackgroundKeepAlive.shared.stop()
            ThirdPartyModuleRuntime.shutdown()
            step = .developerTunnel
        }
    }

}
