import SwiftUI

enum TipKind: String, Identifiable {
    case activation = "生效说明"
    case deactivation = "失效说明"
    case removeProxy = "关闭 WiFi 代理"
    var id: String { rawValue }
}

struct TipSheetView: View {
    let kind: TipKind
    var runtimeMode: ProxyRuntimeMode = .localWiFi
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch kind {
                    case .activation: ActivationTipContent(runtimeMode: runtimeMode, dismiss: { dismiss() })
                    case .deactivation: DeactivationTipContent(runtimeMode: runtimeMode, dismiss: { dismiss() })
                    case .removeProxy: RemoveProxyTipContent(dismiss: { dismiss() })
                    }
                }.padding(16)
            }
            .navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: {
                    Text("知道了").font(.body.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(.blue).padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}

@MainActor
private func openSettings(_ destination: SystemSettingsDestination) {
    guard let appSettingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
    // Try the preferred (private) URL scheme first; fall back to reliable app-settings:
    if let preferredURL = destination.preferredURL, preferredURL != appSettingsURL {
        UIApplication.shared.open(preferredURL) { opened in
            if !opened {
                UIApplication.shared.open(appSettingsURL)
            }
        }
    } else {
        UIApplication.shared.open(appSettingsURL)
    }
}

// MARK: - 生效说明

struct ActivationTipContent: View {
    var runtimeMode: ProxyRuntimeMode = .localWiFi
    let dismiss: () -> Void

    var body: some View {
        GroupBox(label: Label("让虚拟定位生效", systemImage: "checklist")) {
            VStack(alignment: .leading, spacing: 10) {
                if runtimeMode == .developerTunnel {
                    step(1, "连接 LocalDevVPN", "打开 LocalDevVPN 并连上隧道，确认已导入配对文件。")
                    step(2, "开始虚拟定位", "回到地图，点底部「开始虚拟定位」。系统会停在当前图钉，不用再开关定位服务。")
                } else {
                if runtimeMode == .thirdParty {
                    step(0, "确认第三方代理已开启", "保持已导入的 WLOC 模块、HTTPS 解密和第三方代理/VPN 连接开启。")
                }
                step(1, "开启飞行模式", "从控制中心打开飞行模式（点飞机图标），Wi‑Fi 会自动断开。这是为了清除 iOS 的定位缓存。等待 2 秒。")
                step(2, "关闭 Wi‑Fi", "从控制中心再点一下 Wi‑Fi 图标，确认 Wi‑Fi 已关闭。等待 2 秒。")
                systemStep(3, "关闭系统定位服务", "打开系统「设置 → 隐私与安全性 → 定位服务」，关闭顶部的总开关。等待 2 秒。")
                step(4, "打开 Wi‑Fi，启动虚拟定位", runtimeMode == .thirdParty ? "从控制中心打开 Wi‑Fi（飞行模式保持开启），确认第三方代理已连接。坐标已经同步到第三方代理。等待 2 秒。" : "从控制中心打开 Wi‑Fi（飞行模式保持开启），进入 App 点底部「开始虚拟定位」。等待 2 秒。")
                step(5, "关闭飞行模式", "从控制中心关闭飞行模式。等待 2 秒。")
                systemStep(6, "重新开启定位服务", "再次进入「设置 → 隐私与安全性 → 定位服务」，打开总开关。完成后打开地图验证定位是否已变化。")
                }
            }.padding(.vertical, 4)
        }

        if runtimeMode != .developerTunnel {
            GroupBox(label: Label("还是无法生效？", systemImage: "exclamationmark.triangle")) {
                Text("操作到第 3 步时关机重启，开机后从第 4 步继续。这样能彻底清除系统缓存的定位数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.15), in: Circle()).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func systemStep(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.18), in: Circle()).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { openSettings(.locationServices) } label: {
                    Label("去设置", systemImage: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).tint(.blue)
            }
        }
    }
}

// MARK: - 失效说明

struct DeactivationTipContent: View {
    var runtimeMode: ProxyRuntimeMode = .localWiFi
    let dismiss: () -> Void

    var body: some View {
        GroupBox(label: Label("取消虚拟定位", systemImage: "arrow.uturn.backward.circle")) {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "开启飞行模式", "从控制中心打开飞行模式，Wi‑Fi 会自动断开。等待 2 秒。")
                step(2, "关闭 Wi‑Fi", "从控制中心确认 Wi‑Fi 已关闭。等待 2 秒。")
                systemStep(3, "关闭系统定位服务", "打开「设置 → 隐私与安全性 → 定位服务」，关闭总开关。等待 2 秒。")
                if runtimeMode == .thirdParty {
                    step(4, "确认坐标已清除", "App 已通知第三方代理清除虚拟坐标。保持网络可用并等待 2 秒，让系统重新获取真实定位。")
                } else {
                    systemStep(4, "打开 Wi‑Fi，移除代理", "从控制中心打开 Wi‑Fi。然后进入「设置 → 无线局域网 → 点 WiFi 右侧 (i) → HTTP 代理」，选择「关闭」后存储。等待 2 秒。")
                }
                step(5, "关闭飞行模式", "从控制中心关闭飞行模式。等待 2 秒。")
                systemStep(6, "重新开启定位服务", "再次进入「设置 → 隐私与安全性 → 定位服务」打开总开关。打开地图验证定位是否恢复。")
            }.padding(.vertical, 4)
        }

        GroupBox(label: Label("还是无法取消？", systemImage: "exclamationmark.triangle")) {
            Text("操作到第 3 步时关机重启，开机后从第 4 步继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }

    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.blue.opacity(0.15), in: Circle()).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func systemStep(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.caption2.bold())
                .frame(width: 20, height: 20)
                .background(Color.orange.opacity(0.18), in: Circle()).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { openSettings(.locationServices) } label: {
                    Label("去设置", systemImage: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).tint(.blue)
            }
        }
    }
}

// MARK: - 移除 WiFi 代理

struct RemoveProxyTipContent: View {
    let dismiss: () -> Void

    var body: some View {
        GroupBox(label: Label("移除代理配置", systemImage: "wifi.slash")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("停止虚拟定位后，需要手动移除 WiFi 代理配置，否则可能无法上网。\n\n1. 打开「设置 → 无线局域网」\n2. 点击当前 WiFi 右侧 (i) 图标\n3. 找到「HTTP 代理」\n4. 选择「关闭」\n5. 点右上角「存储」")
                    .font(.caption).foregroundStyle(.primary)
                Button { openSettings(.wifi) } label: {
                    Label("去设置", systemImage: "arrow.up.right.square").font(.caption)
                }.buttonStyle(.bordered).tint(.blue)
            }.padding(.vertical, 4)
        }
    }
}
