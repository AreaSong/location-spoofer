import SwiftUI

extension FirstSetupView {
    var modeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择运行模式")
                .font(.title2.bold())
            Text("后续可在“设置 → 运行模式”中切换。APP 模式和第三方模式不要同时拦截定位响应。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let message = appModeNetworkBlockedMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            modeCard(
                title: "APP模式",
                icon: "iphone.and.arrow.forward",
                badges: ["仅 Wi-Fi", "无外部依赖"],
                description: "App 在设备本地启动代理，通过当前 Wi-Fi 的手动 HTTP 代理改写定位响应。免费自签应用无法使用系统 VPN 的 Network Extension 能力，因此 APP模式不支持蜂窝网络，需要配置 Wi-Fi 代理并安装 App 生成的 CA。",
                tint: .blue
            ) {
                selectMode(.localWiFi)
            }
            .disabled(isPreparingMode)

            modeCard(
                title: "LocalDevVPN 模式",
                icon: "location.fill.viewfinder",
                badges: ["定点 + 路线", "系统定位"],
                description: "通过本机隧道把坐标推进系统定位。定点会停在图钉上，路线会跟着走。需要安装 LocalDevVPN，并导入一次配对文件。",
                tint: .green
            ) {
                selectMode(.developerTunnel)
            }
            .disabled(isPreparingMode)

            modeCard(
                title: "第三方代理模式",
                icon: "network.badge.shield.half.filled",
                badges: ["Wi-Fi + 4G/5G", "测试模式"],
                description: "App 负责选点，并通过 WLOC 配置接口查询和同步坐标；第三方代理客户端负责网络代理、模块拦截、MITM 和持久化。证书、VPN 与代理连接均由第三方客户端处理。",
                tint: .orange
            ) {
                selectMode(.thirdParty)
            }
            .disabled(isPreparingMode)

            if isPreparingMode {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在准备 APP模式本地服务…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    func modeCard(
        title: String,
        icon: String,
        badges: [String],
        description: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.25)))
        }
        .buttonStyle(.plain)
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
