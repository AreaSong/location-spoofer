import SwiftUI

extension FirstSetupView {
    var developerTunnelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接开发者隧道")
                .font(.title2.bold())
            Text("定点和路线都通过这条通道推进系统定位。不用小火箭，也不用反复开关定位服务。用 LocalDevVPN 连上隧道并导入配对文件后，点完成。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Form {
                RouteLocationSettingsSection()
            }
            .frame(minHeight: 420)
        }
    }
}
