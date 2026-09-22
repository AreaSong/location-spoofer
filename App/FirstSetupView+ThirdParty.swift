import SwiftUI
import UIKit

extension FirstSetupView {
    var thirdPartyFailureLog: String? {
        guard showsThirdPartyFailureLog else { return nil }
        if let thirdPartyTestFailure {
            return thirdPartyTestFailure.message
        }
        guard !setup.message.isEmpty else { return nil }
        return """
        ======== 第三方代理运行检测 ========
        当前客户端：\(thirdPartyClient.selectedClient.name)
        触发来源：地图或设置中的第三方代理操作
        请求动作：WLOC 配置接口
        检测结果：失败
        原因：\(setup.message)
        处理建议：确认模块已启用，证书已完全信任，并且第三方代理/VPN 已连接。
        """
    }

    var thirdPartyMITMWarning: some View {
        Label {
            Text("iOS 27 beta 6 起，系统已禁止对 gs-loc.apple.com 进行 MITM 拦截。该版本及之后的 beta 版本暂时无法使用本项目，等待后续适配方案。")
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    var thirdPartyClientStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            thirdPartyMITMWarning
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            GroupBox(label: Label("选择第三方代理客户端", systemImage: "app.badge.checkmark")) {
                VStack(spacing: 0) {
                    ForEach(ThirdPartyProxyClient.allCases) { client in
                        Button {
                            thirdPartyClient.select(client)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(client.name).foregroundStyle(.primary)
                                    if let verificationText = client.verificationText {
                                        Text(verificationText)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: thirdPartyClient.selectedClient == client ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(thirdPartyClient.selectedClient == client ? .blue : .secondary)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if client != ThirdPartyProxyClient.allCases.last { Divider() }
                    }
                }
            }

            Text("除 Shadowrocket 外，当前客户端配置尚未完成真机验证，页面只提供模块导入入口和通用配置提醒。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            DisclosureGroup("第三方客户端适配说明") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("工作原理")
                        .font(.subheadline.bold())
                    Text("App 不连接远程坐标服务器，而是向 Apple 域名发起一个约定请求。第三方客户端需要在本机拦截该请求、保存 WGS-84 坐标并返回 JSON；定位模块再读取同一份数据，修改 Apple WLOC 响应。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("配置接口")
                        .font(.subheadline.bold())
                    Text(ThirdPartyProxyManager.configurationEndpoint.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("""
                    查询：GET ?action=query
                    保存：GET ?lon=<经度>&lat=<纬度>&acc=<精度>
                    清除：GET ?action=clear
                    """)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("返回格式")
                        .font(.subheadline.bold())
                    Text("""
                    成功：{"success":true,"longitude":113.0,"latitude":22.0,"accuracy":25}
                    失败：{"success":false,"error":"错误说明"}
                    """)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("适配要求")
                        .font(.subheadline.bold())
                    Text("客户端需要支持请求脚本、持久化存储、HTTP 200 JSON 响应、Apple WLOC 响应脚本，以及 Apple 定位域名（gs-loc.apple.com、gsp-ssl.ls.apple.com、bluedot.is.autonavi.com 等）的 HTTPS 解密。保存接口和 WLOC 响应脚本必须读取同一份持久化数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    var thirdPartyImportStep: some View {
        let client = thirdPartyClient.selectedClient
        return VStack(alignment: .leading, spacing: 16) {
            thirdPartyMITMWarning
            if showThirdPartyRepairReason {
                Label(
                    "检测到第三方代理连接异常，请检查模块、MITM 和代理连接后重新检测。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("第 1 步：导入 \(client.name) 模块", systemImage: "square.and.arrow.down")) {
                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(1, "复制 \(client.name) 的模块订阅地址。本机地址导入或更新时请保持本 App 打开，不要杀掉。")
                    Button {
                        ThirdPartyModuleRuntime.prepareForImport()
                        UIPasteboard.general.string = client.subscriptionURL.absoluteString
                        copiedSubscriptionURL = true
                    } label: {
                        Label(copiedSubscriptionURL ? "已复制模块订阅地址" : "复制模块订阅地址", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("当前来源：\(moduleSource.distribution.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(client.subscriptionURL.absoluteString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DisclosureGroup("高级") {
                        Picker("模块来源", selection: Binding(
                            get: { moduleSource.distribution },
                            set: { newValue in
                                moduleSource.setDistribution(newValue)
                                ThirdPartyModuleRuntime.syncServerWithDistribution()
                            }
                        )) {
                            ForEach(ThirdPartyModuleDistribution.allCases) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .pickerStyle(.menu)
                        Text("换来源只影响下次导入，不能替代小火箭拦定位。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    instructionRow(2, client == .shadowrocket
                        ? "打开 Shadowrocket，进入“配置 → 模块”。"
                        : "打开 \(client.name)。")
                    Button {
                        ThirdPartyModuleRuntime.prepareForImport()
                        openThirdPartyClient(client)
                    } label: {
                        Label("打开 \(client.name)", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if client == .shadowrocket {
                        setupScreenshot(
                            assetName: "ShadowrocketConfigDetails",
                            title: "进入 Shadowrocket 配置",
                            caption: "1 点击「模块」进入模块列表，2 可打开当前本地配置详情。"
                        )
                    }

                    if client == .shadowrocket {
                        instructionRow(3, "点击右上角“+”，粘贴模块订阅地址并导入，然后确认模块已启用。")
                        setupScreenshot(
                            assetName: "ShadowrocketModuleImport",
                            title: "导入 Shadowrocket 模块",
                            caption: "1 点击右上角加号导入模块，2 确认模块已启用。"
                        )
                    } else {
                        instructionRow(3, "在 \(client.name) 中导入刚才复制的模块订阅地址。")
                    }
                }
            }

            if client == .shadowrocket {
                shadowrocketHTTPSDecryptionGuide
            } else {
                GroupBox(label: Label("第 2 步：完成 \(client.name) 配置", systemImage: "slider.horizontal.3")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("请在 \(client.name) 中完成相应配置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("配置时请复制下方全部解密域名（含 gsp-ssl.ls.apple.com、bluedot.is.autonavi.com）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        mitmHostnameCopyButton
                    }
                }
            }

            if let thirdPartyFailureLog {
                testResultView(
                    success: false,
                    title: "接口连接失败",
                    log: thirdPartyFailureLog
                )
                .id("thirdPartyFailureLog")
            }
        }
    }

    var shadowrocketHTTPSDecryptionGuide: some View {
        GroupBox(label: Label("第 2 步：配置 HTTPS 解密", systemImage: "lock.open")) {
            VStack(alignment: .leading, spacing: 12) {
                instructionRow(1, "进入“配置 → 本地文件”，找到带黄点的配置，点击右侧 i 图标。")
                instructionRow(2, "进入“HTTPS 解密”，开启解密开关。")
                instructionRow(3, "在域名列表中添加下方复制的全部解密域名。")
                setupScreenshot(
                    assetName: "ShadowrocketHTTPSDecryption",
                    title: "配置 HTTPS 解密",
                    caption: "1 开启 HTTPS 解密，2 添加复制的全部解密域名，3 打开证书设置。"
                )

                mitmHostnameCopyButton

                instructionRow(4, "按 Shadowrocket 提示生成并完成证书授权。")
                setupScreenshot(
                    assetName: "ShadowrocketHTTPSCA",
                    title: "授权 Shadowrocket 证书",
                    caption: "1 打开 Shadowrocket 证书项并按提示安装、授权。"
                )
                instructionRow(5, "返回 HTTPS 解密页面，点击右上角勾号保存，然后开启代理。")

                Button {
                    openThirdPartyClient(.shadowrocket)
                } label: {
                    Label("打开 Shadowrocket 继续配置", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("App 只能唤起 Shadowrocket，无法通过公开接口直接跳转到“模块”或“HTTPS 解密”页面。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var mitmHostnameCopyButton: some View {
        Button {
            UIPasteboard.general.string = ThirdPartyProxyManager.interceptionHostnamesText
            copiedMITMHostname = true
        } label: {
            Label(
                copiedMITMHostname ? "已复制解密域名" : "复制解密域名",
                systemImage: "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func openThirdPartyClient(_ client: ThirdPartyProxyClient) {
        guard let url = client.launchURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                manualHint = "无法打开 \(client.name)，请确认客户端已安装后手动打开。"
            }
        }
    }

    func verifyThirdPartyConnection() {
        guard !isVerifying else { return }
        let client = thirdPartyClient.selectedClient
        let startedAt = Date()
        isVerifying = true
        result = nil
        thirdPartyTestFailure = nil
        showsThirdPartyFailureLog = false
        setup.message = ""
        RuntimeLogger.info("APP", "ThirdPartyProxy", "开始第三方代理连接检测", details: [
            "当前客户端": client.name,
            "请求动作": "WLOC query",
            "检查范围": "模块拦截、MITM、代理/VPN连接"
        ])
        Task { @MainActor in
            defer { isVerifying = false }
            do {
                let response = try await thirdPartyProxy.query()
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                RuntimeLogger.info("APP", "ThirdPartyProxy", "第三方代理连接检测通过", details: [
                    "当前客户端": client.name,
                    "请求动作": "WLOC query",
                    "连接状态": response.latitude == nil || response.longitude == nil ? "已连接，无保存坐标" : "已连接，有保存坐标",
                    "耗时毫秒": String(elapsedMilliseconds)
                ])
                onComplete()
            } catch {
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                let connectionState = thirdPartyConnectionStateDescription
                let diagnosis = ThirdPartyProxyError.diagnosis(for: error)
                let suggestion = ThirdPartyProxyError.recoverySuggestion(for: error)
                RuntimeLogger.error(
                    "APP",
                    "ThirdPartyProxy",
                    "第三方代理连接检测失败",
                    error: error,
                    details: [
                        "当前客户端": client.name,
                        "请求动作": "WLOC query",
                        "连接状态": connectionState,
                        "耗时毫秒": String(elapsedMilliseconds),
                        "原因": diagnosis.title,
                        "处理建议": suggestion
                    ]
                )
                thirdPartyTestFailure = ThirdPartyConnectionTestFailure(
                    message: """
                    ======== 第三方代理连接检测 ========
                    当前客户端：\(client.name)
                    配置接口：/wloc-settings/save
                    请求动作：WLOC query
                    检查范围：模块拦截、MITM、证书、代理/VPN 连接
                    连接状态：\(connectionState)
                    检测结果：失败
                    耗时：\(elapsedMilliseconds) ms
                    原因：\(diagnosis.title)
                    处理建议：\(suggestion)。
                    """
                )
                showsThirdPartyFailureLog = true
            }
        }
    }

    var thirdPartyConnectionStateDescription: String {
        switch thirdPartyProxy.connectionState {
        case .unknown:
            return "未检测"
        case .connected(let active):
            return active ? "已连接，有保存坐标" : "已连接，无保存坐标"
        case .failed(let message):
            return "连接失败（\(message)）"
        }
    }

}
