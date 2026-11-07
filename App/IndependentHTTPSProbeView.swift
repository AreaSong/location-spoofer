import SwiftUI
import UIKit

struct IndependentHTTPSProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var running = false
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("实验功能，仅用于小火箭。探测只请求固定标识，不读取、保存或清除坐标，也不修改当前定位状态。")
                    Button("复制小火箭探测模块地址") { copyModuleURL() }
                        .disabled(running)
                    Text("保持本 App 运行，在小火箭导入并启用探测模块，全局路由选择「配置」，然后返回执行探测。全局「代理」可能导致本机脚本下载超时。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        running = true
                        message = "正在检查独立 HTTPS 连接…"
                        probeTask = Task {
                            let result = await IndependentHTTPSProbe.run()
                            if !Task.isCancelled { message = result }
                            running = false
                        }
                    } label: {
                        HStack {
                            Text(running ? "正在探测…" : "运行独立 HTTPS 探测")
                            if running { ProgressView() }
                        }
                    }
                    .disabled(running)
                    if !message.isEmpty {
                        Text(message).textSelection(.enabled)
                        CopyButton("复制结果", value: { message })
                    }
                } footer: {
                    Text("HTTPS 仍由系统校验证书；不会忽略证书错误或降级到 HTTP。通过只代表探测链路可用，不代表系统定位已改变。")
                }
            }
            .navigationTitle("独立 HTTPS 探测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }
        .onDisappear { probeTask?.cancel() }
    }

    private func copyModuleURL() {
        do {
            try ThirdPartyModuleServer.shared.start()
            UIPasteboard.general.string = ThirdPartyModuleCatalog.subscriptionURL(
                moduleFileName: IndependentHTTPSProbe.moduleFileName, distribution: .onDevice
            ).absoluteString
            message = "已复制本机探测模块地址。请在小火箭导入；探测脚本不会操作坐标存储。"
        } catch {
            message = "无法提供本机探测模块：\(error.localizedDescription)"
        }
    }
}
