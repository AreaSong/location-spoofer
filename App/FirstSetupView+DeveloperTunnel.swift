import SwiftUI

extension FirstSetupView {
    var developerTunnelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接开发者隧道")
                .font(.title2.bold())
            Text("定点和路线都通过这条通道推进系统定位。不用小火箭，也不用反复开关定位服务。三项都打勾后，点完成。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if developerMode {
                Label("开发者模式：隧道按已就绪显示，不会连接本机隧道。", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            GroupBox(label: Label("就绪清单", systemImage: "checklist")) {
                RouteLocationChecklist()
                    .padding(.top, 6)
            }

            DisclosureGroup("配对文件怎么生成") {
                VStack(alignment: .leading, spacing: 10) {
                    instructionRow(1, "用数据线把手机连到电脑，解锁手机并信任这台电脑。")
                    instructionRow(2, "在电脑上用 idevice 工具生成 RemotePairing 配对文件。")
                    instructionRow(3, "通过 AirDrop 或“文件”App 传到手机，回到这里点“导入”选中它。")
                    Text("详细命令见项目 README。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.medium))
        }
    }
}
