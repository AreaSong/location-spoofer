import SwiftUI
import UniformTypeIdentifiers

/// 开发者隧道三项就绪清单：LocalDevVPN、本机隧道、配对文件。引导页和设置页共用。
/// 每行带状态图标和一个内联动作，回到前台时自动刷新。
struct RouteLocationChecklist: View {
    @ObservedObject var setup = RouteLocationSetupStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsImporter = false
    @State private var importError = ""

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
            checklistRow(
                title: "配对文件",
                ready: setup.status.hasPairing,
                readyText: "已导入",
                missingText: "未导入",
                actionTitle: setup.status.hasPairing ? "重新导入" : "导入",
                action: { showsImporter = true }
            )
            Text("路线播放会把坐标推进系统定位，不用反复开关定位服务。请先连上 LocalDevVPN，并导入 RPPairing 文件。iOS 18 到 26 用电脑生成一次即可。需要 iOS 18 或更新的系统。")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    private func importPairing(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            importError = "没有读到配对文件。"
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try setup.importPairing(data)
                importError = ""
            } catch {
                importError = "这份文件不是配对文件。"
            }
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
