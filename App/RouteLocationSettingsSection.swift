import SwiftUI
import UniformTypeIdentifiers

struct RouteLocationSettingsSection: View {
    @ObservedObject var setup = RouteLocationSetupStore.shared
    @State private var showsImporter = false
    @State private var importError = ""

    var body: some View {
        Section("路线定位") {
            statusRow("LocalDevVPN", ready: setup.status.vpnInstalled, readyText: "已安装", missingText: "未安装")
            statusRow("本机隧道", ready: setup.status.tunnelConnected, readyText: "已连接", missingText: "未连接")
            statusRow("配对文件", ready: setup.status.hasPairing, readyText: "已导入", missingText: "未导入")
            Button {
                LocalDevVPN.openOrInstall()
            } label: {
                Label(
                    setup.status.vpnInstalled ? "打开 LocalDevVPN" : "安装 LocalDevVPN",
                    systemImage: "network"
                )
            }
            Button {
                showsImporter = true
            } label: {
                Label("导入配对文件", systemImage: "doc.badge.plus")
            }
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
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.pairingTypes) { result in
            importPairing(result)
        }
    }

    private func statusRow(_ title: String, ready: Bool, readyText: String, missingText: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ready ? readyText : missingText)
                .foregroundStyle(ready ? Color.secondary : Color.orange)
        }
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
