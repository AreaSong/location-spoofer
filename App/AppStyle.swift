import SwiftUI
import UIKit

/// 全局圆角尺度。卡片、控件、内嵌块和图片各一档，不再散落魔法数。
enum AppRadius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
    static let inset: CGFloat = 10
    static let image: CGFloat = 8
}

/// 首页底部卡展开区相对屏幕高度的上限，避免挡住大半地图。
enum AppLayout {
    static let bottomCardExpandedHeightFraction: CGFloat = 0.28
    /// 定点/路线条高度：内边距 4×2 + 选项 44。
    static let homeModeBarHeight: CGFloat = 52
    /// 模式条与卡片之间的间距。
    static let homeFunctionStackSpacing: CGFloat = 8
    /// 定点/路线共用的底部卡片高度：标题行 + 两行滑动条 + 主按钮，切换时不跳动。
    static let homeFunctionCardHeight: CGFloat = 220
    /// 底部卡片内边距。
    static let homeFunctionCardPadding: CGFloat = 10
    /// 模式条 + 间距 + 卡片，整块功能控件的锁定高度。
    static var homeFunctionClusterHeight: CGFloat {
        homeModeBarHeight + homeFunctionStackSpacing + homeFunctionCardHeight
    }
    /// 地图缩放条边长，与首页坐标条左下的缩放控件对齐。
    static let mapZoomControlSize: CGFloat = 52
    /// 图层 / 系统地图 / 回到定位 三个圆钮加间距，贴在定点/路线条右上角。
    static let mapToolButtonSize: CGFloat = 48
    static let mapToolStackSpacing: CGFloat = 8
    /// 功能面板在缩放条右侧的宽度上限。
    static let homeWalkPopoverMaxWidth: CGFloat = 340
}

/// 地图页顶部圆形图标按钮。直接打开目标页，避免 SwiftUI Menu 叠在 MKMapView 上时第二次点击被地图手势吃掉。
struct MapChromeIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isPhotographic: Bool = false
    let action: () -> Void

    init(systemImage: String, accessibilityLabel: String, isPhotographic: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.isPhotographic = isPhotographic
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: AppLayout.mapToolButtonSize, height: AppLayout.mapToolButtonSize)
                .background(isPhotographic ? AnyShapeStyle(.ultraThickMaterial) : AnyShapeStyle(.regularMaterial), in: Circle())
                .overlay(
                    Circle()
                        .stroke(isPhotographic ? Color.white.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: isPhotographic ? 1.0 : 0.5)
                )
                .shadow(color: .black.opacity(isPhotographic ? 0.28 : 0.14), radius: isPhotographic ? 11 : 9, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(MapChromeIconStyle())
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MapChromeIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 坐标条左下的缩放条。采用 iOS 26 紧凑液态毛玻璃设计，触感步进，释放地图视野。
struct MapZoomControls: View {
    let scaleLabel: String
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.light()
                onZoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: AppLayout.mapZoomControlSize, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HomeInteractiveButtonStyle())
            .accessibilityLabel("放大地图")

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 24, height: 0.75)

            Text(scaleLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .frame(width: AppLayout.mapZoomControlSize, height: 24)
                .accessibilityLabel("当前地图比例 \(scaleLabel)")

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 24, height: 0.75)

            Button {
                Haptics.light()
                onZoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: AppLayout.mapZoomControlSize, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HomeInteractiveButtonStyle())
            .accessibilityLabel("缩小地图")
        }
        .foregroundStyle(.primary)
        .frame(width: AppLayout.mapZoomControlSize)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize()
        .accessibilityIdentifier("home.zoom")
    }
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

/// 主按钮：白字。默认 headline、竖向 14pt；底栏用 compact 收成更矮的一行。禁用时底色减淡。
struct PrimaryActionStyle: ButtonStyle {
    var tint: Color
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    init(tint: Color = .accentColor, compact: Bool = false) {
        self.tint = tint
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.vertical, compact ? 8 : 14)
            .background(
                tint.opacity(isEnabled ? 1 : 0.45),
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 首页按钮按压物理微缩放样式
struct HomeInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
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

/// 全局触感反馈中心。对 UIKit 的 Feedback Generator 进行轻量收敛与防卡顿优化。
@MainActor
enum Haptics {
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionFeedback = UISelectionFeedbackGenerator()
    private static let notificationFeedback = UINotificationFeedbackGenerator()

    /// 轻微敲击（如地图落针、小按钮轻点）
    static func light() {
        lightImpact.prepare()
        lightImpact.impactOccurred()
    }

    /// 中度碰撞（如开始虚拟定位、切换到此处）
    static func medium() {
        mediumImpact.prepare()
        mediumImpact.impactOccurred()
    }

    /// 选项切换反馈（如选择收藏、切换定点/路线、点击图钉）
    static func selection() {
        selectionFeedback.prepare()
        selectionFeedback.selectionChanged()
    }

    /// 成功通知反馈（如定位成功生效、复制坐标成功、保存路线成功）
    static func success() {
        notificationFeedback.prepare()
        notificationFeedback.notificationOccurred(.success)
    }

    /// 警告反馈（如网络异常、不可用）
    static func warning() {
        notificationFeedback.prepare()
        notificationFeedback.notificationOccurred(.warning)
    }
}
