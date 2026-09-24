import SwiftUI
import UIKit

extension FirstSetupView {
    var proxyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(label: Label("先配置 Wi-Fi 系统代理", systemImage: "wifi")) {
                Text("在当前 Wi-Fi 的详情页，将「HTTP 代理」设为「手动」：服务器填 127.0.0.1，端口填 8888。配置后点击下方「完成」。检测会自动判断是 Wi-Fi 代理还是证书信任有问题。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            setupScreenshot(
                assetName: "AppModeWiFiProxy",
                title: "Wi-Fi 代理设置",
                caption: "1 选择手动，2 填写服务器 127.0.0.1，3 填写端口 8888。"
            )
            HStack(spacing: 12) {
                Button { UIPasteboard.general.string = "127.0.0.1:8888" } label: {
                    Label("复制地址", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { openSettings(.wifi) } label: {
                    Label("打开 Wi-Fi 设置", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    var certificateStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            certificateCard(
                title: "第 1 步：下载证书",
                icon: "arrow.down.circle",
                description: "下载本机随机生成的 CA 根证书。私钥仅保存在此设备的钥匙串中，不会随证书文件导出。App 会弹出 Safari 下载页；出现配置描述文件下载提示时，选择「允许」。",
                actionTitle: "打开下载页",
                actionIcon: "arrow.down.circle.fill",
                complete: downloadedDone,
                action: {
                    Task {
                        if let url = await setup.proxy.prepareCertificateDownloadURL() {
                            certificateDownloadDestination = CertificateDownloadDestination(url: url)
                        } else {
                            setupActionError = setup.proxy.error ?? "无法准备证书下载页面，请查看诊断日志"
                        }
                    }
                },
                markComplete: { downloadedDone = true }
            )
            certificateCard(
                title: "第 2 步：安装证书",
                icon: "square.and.arrow.down",
                description: "下载完成后打开系统「设置」。如果顶部显示「已下载描述文件」，点进去安装；否则进入「通用 → VPN 与设备管理」，找到 Location Spoofer CA 并完成安装。",
                actionTitle: "去安装",
                actionIcon: "gearshape",
                complete: installedDone,
                action: { openSettings(.general) },
                markComplete: { installedDone = true }
            )
            setupScreenshot(
                assetName: "AppModeCertificateInstall",
                title: "安装证书",
                caption: "1 在「VPN 与设备管理」中打开 Location Spoofer CA 描述文件并完成安装。"
            )
            certificateCard(
                title: "第 3 步：信任证书",
                icon: "shield.checkered",
                description: "安装后进入「设置 → 通用 → 关于本机 → 证书信任设置」，找到 Location Spoofer CA 并开启完全信任。iOS 保留钥匙串数据时，重装 App 会继续复用同一证书。",
                actionTitle: "去信任",
                actionIcon: "shield.checkered",
                complete: trustedDone,
                action: { openSettings(.general) },
                markComplete: { trustedDone = true }
            )
            setupScreenshot(
                assetName: "AppModeCertificateTrust",
                title: "信任证书",
                caption: "1 在「证书信任设置」中为 Location Spoofer CA 开启完全信任。"
            )
        }
    }

    @ViewBuilder
    func setupScreenshot(
        assetName: String,
        title: String,
        caption: String
    ) -> some View {
        if let image = UIImage(named: assetName) {
            Button {
                screenshotPreview = SetupScreenshotPreview(
                    image: image,
                    title: title
                )
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text(caption)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.image))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.image)
                        .stroke(Color.secondary.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)：\(caption)")
            .accessibilityHint("轻点查看大图")
        }
    }

    func certificateCard(
        title: String,
        icon: String,
        description: String,
        actionTitle: String,
        actionIcon: String,
        complete: Bool,
        action: @escaping () -> Void,
        markComplete: @escaping () -> Void
    ) -> some View {
        GroupBox(label: Label(title, systemImage: icon)) {
            VStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 0).padding(.top, 2)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionIcon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    Button(action: markComplete) {
                        Label(
                            complete ? "已完成 ✓" : "已完成",
                            systemImage: complete ? "checkmark.circle.fill" : "circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(complete ? .green : .secondary)
                }
            }
        }
    }

    func verifyAfterProxyConfirmation() {
        runVerification { result in
            if result.isSuccess {
                onComplete()
            } else if result == .certNotTrusted {
                step = .cert
            } else {
                step = .proxy
            }
        }
    }

    func verifyAfterCertificateConfirmation() {
        runVerification { result in
            if result.isSuccess {
                onComplete()
            } else if result != .certNotTrusted {
                step = .proxy
            }
        }
    }

    @MainActor
    func openSettings(_ destination: SystemSettingsDestination) {
        SystemSettingsNavigator.open(destination) { fallbackHint in
            if let fallbackHint { manualHint = fallbackHint }
        }
    }

}
