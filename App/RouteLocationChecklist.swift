import SwiftUI
import UniformTypeIdentifiers

/// 开发者隧道三项就绪清单：LocalDevVPN、本机隧道、配对文件。引导页和设置页共用。
/// 每行带状态图标和一个内联动作，回到前台时自动刷新。
struct RouteLocationChecklist: View {
    @ObservedObject var setup = RouteLocationSetupStore.shared
    var session: SpoofSession? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsImporter = false
    @State private var showsDeleteConfirm = false
    @State private var importError = ""
    @State private var actionMessage = ""
    @State private var actionIsWarning = false
    @State private var isResettingCache = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            checklistRow(
                title: "LocalDevVPN",
                ready: setup.status.vpnInstalled,
                readyText: "已安装",
                missingText: "未安装",
                actionTitle: setup.status.vpnInstalled ? "打开" : "安装",
                action: LocalDevVPN.openOrInstall
            )
            checklistRow(
                title: "本机隧道",
                ready: setup.status.tunnelConnected,
                readyText: "已连接",
                missingText: "未连接",
                actionTitle: "打开 LocalDevVPN",
                actionDisabled: !setup.status.vpnInstalled,
                action: LocalDevVPN.openOrInstall
            )
            tunnelActivity
            checklistRow(
                title: "配对文件",
                ready: setup.status.hasPairing,
                readyText: "已导入",
                missingText: "未导入",
                actionTitle: setup.status.hasPairing ? "替换" : "导入",
                action: { showsImporter = true }
            )
            if setup.status.hasPairing {
                Button("删除配对文件", role: .destructive) {
                    showsDeleteConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("路线播放会把坐标推进系统定位，不用反复开关定位服务。请先连上 LocalDevVPN，并导入 RPPairing 文件。iOS 18 到 26 用电脑生成一次即可。需要 iOS 18 或更新的系统。只开流量、关掉 Wi-Fi 时系统通常连不上本机隧道，请打开 Wi-Fi（不用上网）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !actionMessage.isEmpty {
                Text(actionMessage)
                    .font(.footnote)
                    .foregroundStyle(actionIsWarning ? Color.orange : Color.secondary)
            }
            if !importError.isEmpty {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { setup.refresh() }
        .onChange(of: scenePhase) { phase in
            // 从 LocalDevVPN 切回来时立刻刷新，不用用户再点一下。
            if phase == .active { setup.refresh() }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.pairingTypes) { result in
            importPairing(result)
        }
        .confirmationDialog("删除配对文件？", isPresented: $showsDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await deletePairing() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会先关掉系统模拟定位。关不掉时文件会留下来，方便重试清除。")
        }
    }

    private var tunnelActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(setup.activity.diagnosticText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button {
                restoreRealLocation()
            } label: {
                Label(setup.isClearing ? "正在恢复…" : "恢复真实定位", systemImage: "location.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(setup.isClearing || isResettingCache || session?.state == .verifying)
            Button {
                Task { await resetTunnelCache() }
            } label: {
                Label(isResettingCache ? "正在清理…" : "清理隧道会话", systemImage: "xmark.bin")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(setup.isClearing || isResettingCache || session?.state == .verifying)
            Text("恢复真实定位会关掉系统模拟。清理隧道会话只丢掉卡住的连接，不删除配对文件。虚拟定位用着用着连不上时，先点这个再重连 LocalDevVPN。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func restoreRealLocation() {
        actionMessage = ""
        actionIsWarning = false
        if let session {
            session.stop()
            actionMessage = "正在恢复真实定位。"
            return
        }
        Task {
            if let failure = await setup.clear() {
                actionMessage = failure.message
                actionIsWarning = true
            } else {
                actionMessage = "已恢复真实定位。"
                actionIsWarning = false
            }
        }
    }

    private func resetTunnelCache() async {
        isResettingCache = true
        defer { isResettingCache = false }
        let message = await setup.resetTunnelCache()
        session?.noteExternalClear()
        actionIsWarning = message.contains("可能还停在虚拟点")
        actionMessage = message
    }

    private func checklistRow(
        title: String,
        ready: Bool,
        readyText: String,
        missingText: String,
        actionTitle: String,
        actionDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title3)
                .foregroundStyle(ready ? Color.green : Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(ready ? readyText : missingText)
                    .font(.caption)
                    .foregroundStyle(ready ? Color.secondary : Color.orange)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(actionDisabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func deletePairing() async {
        if let message = await setup.deletePairing() {
            importError = message
        } else {
            importError = ""
        }
    }

    private func importPairing(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            importError = "没有读到配对文件。"
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        Task {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            await importPairingFile(url)
        }
    }

    private func importPairingFile(_ url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            try await setup.importPairing(data)
            importError = ""
        } catch {
            importError = "这份文件不是配对文件。"
        }
    }

    private static var pairingTypes: [UTType] {
        var types: [UTType] = [.data, .propertyList, .xml, .item]
        if let plist = UTType(filenameExtension: "plist") {
            types.append(plist)
        }
        return types
    }
}
