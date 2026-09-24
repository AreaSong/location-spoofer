import SwiftUI

/// 设置页和路线定位 sheet 里的“路线定位”分组，内容就是共用的就绪清单。
struct RouteLocationSettingsSection: View {
    var body: some View {
        Section("路线定位") {
            RouteLocationChecklist()
        }
    }
}
