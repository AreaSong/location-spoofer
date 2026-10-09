import SwiftUI

extension MapHomeView {
    var homeSettingsButton: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HomeSettingsButton(
                status: SigningExpiry.evaluate(expirationDate: signingExpiryStatus.expirationDate, now: context.date),
                now: context.date,
                onOpen: { activeSheet = .settings }
            )
        }
    }
}

/// 签名仅在设置入口作轻量提示；完整时间、重签说明与过期门禁继续使用原有来源。
struct HomeSettingsButton: View {
    let status: SigningExpiryStatus
    let now: Date
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 2) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                if let text = compactText {
                    Text(text)
                        // 固定小标注不挤压图标；完整内容通过设置页与无障碍值提供。
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(status.showsMapBanner ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: AppLayout.mapToolButtonSize, height: AppLayout.mapToolButtonSize)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
            .contentShape(Circle())
        }
        .buttonStyle(MapChromeIconStyle())
        .accessibilityLabel("设置")
        .accessibilityValue(status.expirationDate.flatMap { SigningExpiryCountdown.text(until: $0, now: now) }
                            ?? status.settingsMessage ?? "")
        .accessibilityHint("查看设置与签名详情")
        .accessibilityIdentifier("home.settings")
    }

    private var compactText: String? {
        switch status.kind {
        case .unknown, .longLived: return nil
        case .expired: return "已到期"
        case .remaining:
            guard let expiration = status.expirationDate else { return nil }
            let parts = Calendar.current.dateComponents([.day, .hour, .minute], from: now, to: expiration)
            if let days = parts.day, days > 0 { return "\(days)天" }
            if let hours = parts.hour, hours > 0 { return "\(hours)小时" }
            if let minutes = parts.minute, minutes > 0 { return "\(minutes)分" }
            return "即将到期"
        }
    }
}
