import SwiftUI
import UIKit

/// 全局圆角尺度。卡片、控件、内嵌块和图片各一档，不再散落魔法数。
enum AppRadius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
    static let inset: CGFloat = 10
    static let image: CGFloat = 8
}

/// 小胶囊按钮：视觉高度 32pt，命中区域外扩到 44pt，按下时变淡。
struct CapsuleChipStyle: ButtonStyle {
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    init(tint: Color? = nil) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        let color = tint ?? Color.secondary
        return configuration.label
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(color.opacity(tint == nil ? 0.1 : 0.14), in: Capsule())
            .contentShape(Rectangle().inset(by: -6))
            .opacity(configuration.isPressed ? 0.6 : (isEnabled ? 1 : 0.4))
    }
}

/// 主按钮：白字、headline、竖向 14pt 内边距。禁用时底色减淡。
struct PrimaryActionStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    init(tint: Color = .accentColor) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .background(
                tint.opacity(isEnabled ? 1 : 0.45),
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// 复制按钮：点一下写入剪贴板，显示“已复制”，1.5 秒后自动复位。
/// `value` 返回 nil 表示这次没有可复制的内容，不切换状态。
struct CopyButton<Content: View>: View {
    let value: () -> String?
    let content: (Bool) -> Content
    @State private var copied = false
    @State private var generation = 0

    init(value: @escaping () -> String?, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.value = value
        self.content = content
    }

    var body: some View {
        Button(action: copy) {
            content(copied)
        }
    }

    private func copy() {
        guard let text = value() else { return }
        UIPasteboard.general.string = text
        generation += 1
        let current = generation
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard generation == current else { return }
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }
}

extension CopyButton where Content == CopyButtonLabel {
    init(
        _ title: String,
        copiedTitle: String = "已复制",
        systemImage: String = "doc.on.doc",
        fillsWidth: Bool = false,
        value: @escaping () -> String?
    ) {
        self.init(value: value) { copied in
            CopyButtonLabel(
                title: copied ? copiedTitle : title,
                systemImage: copied ? "checkmark" : systemImage,
                fillsWidth: fillsWidth
            )
        }
    }
}

struct CopyButtonLabel: View {
    let title: String
    let systemImage: String
    let fillsWidth: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}

/// 状态行：彩色圆点 + 文字 + 右侧 chevron，整行可点。
struct StatusPill: View {
    enum Tone {
        case ok, warn, error, neutral

        var color: Color {
            switch self {
            case .ok: return .green
            case .warn: return .orange
            case .error: return .red
            case .neutral: return .gray
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
