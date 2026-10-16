import SwiftUI

// MARK: - 强调色对立色

/// 强调色**上面**的文字 / 图标色。
///
/// 黑白主题的强调色是 `Color.primary`（浅色下近黑、深色下近白），
/// 压在它上面的内容必须取对立色 —— 浅色下白字、深色下黑字。
/// 这个值同样走环境传递，理由和 `themeAccent` 一样：
/// 值变了只有真正读它的视图重新求值。
private struct ThemeOnAccentKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

extension EnvironmentValues {
    var themeOnAccent: Color {
        get { self[ThemeOnAccentKey.self] }
        set { self[ThemeOnAccentKey.self] = newValue }
    }
}

// MARK: - 图标章

/// 设置行的图标章。
///
/// 2026-10-13 用户拿上一代设置页截图拍板：图标章从圆角方章改回**实心圆**、
/// 加大到 36pt（上一代同尺寸），底色 = 主题强调色，图标 = 对立色。
/// 黑白主题下自动是「浅色模式：黑圆白图标 / 深色模式：白圆黑图标」。
struct SettingsIconBadge: View {

    let systemImage: String

    @Environment(\.themeAccent) private var accent
    @Environment(\.themeOnAccent) private var onAccent

    var body: some View {
        ZStack {
            Circle().fill(accent)
            Image(systemName: systemImage)
                .font(.app(15, weight: .semibold))
                .foregroundStyle(onAccent)
        }
        .frame(width: Tokens.Size.settingsIcon, height: Tokens.Size.settingsIcon)
    }
}

// MARK: - 列表行

/// 设置列表里的一行：图标 + 标题 + 右侧取值 + 可选箭头。
///
/// **右侧取值不加箭头**：只读的状态行加了 `chevron`，等于告诉用户
/// 「这里能点」，点下去却什么都不动。需要跳转的行才传 `showsChevron: true`。
struct SettingsRow: View {

    let systemImage: String
    let title: String

    /// 标题下的灰色说明行（上一代实现同款「未设置昵称 / 点击设置头像和昵称」）。
    /// nil = 不显示。
    var subtitle: String?

    /// 右侧当前取值。nil = 不显示。
    var value: String?

    /// 取值文字颜色（例如「已信任」标绿）。
    var valueColor: Color = .ncTextSecondary

    /// 是否显示右侧箭头。**只读行不要开。**
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.rowIcon) {
            SettingsIconBadge(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.app(16))
                    .foregroundStyle(Color.ncText)

                if let subtitle {
                    Text(subtitle)
                        .font(.app(13))
                        .foregroundStyle(Color.ncTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.app(16))
                    .foregroundStyle(valueColor)
                    // 防溢出双保险（2026-10-13「脚本回读」长文案顶出卡片实锤）：
                    // 最多两行、纵向自适应 —— 再长的取值也只是把行撑高，
                    // 不会再横向顶破卡片。超长文案的正确归宿仍是行下说明段。
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.app(13, weight: .semibold))
                    .foregroundStyle(Color.ncTextTertiary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.row)
        // 行高放到 60 上下（图标 36 + 上下 12）：2026-10-13 用户反馈旧版
        // 「很紧凑、很拥挤」，按上一代截图放宽。
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// 带开关的列表行。
struct SettingsToggleRow: View {

    let systemImage: String
    let title: String

    /// 标题下的说明行，可随开关状态动态切换（例如自动校验的两种行为说明）。
    var subtitle: String?

    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.rowIcon) {
            SettingsIconBadge(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.app(16))
                    .foregroundStyle(Color.ncText)

                if let subtitle {
                    Text(subtitle)
                        .font(.app(13))
                        .foregroundStyle(Color.ncTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color.themeAccentValue)
        }
        .padding(.horizontal, Tokens.Spacing.row)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - 分组卡片

/// 设置页的分组：小标题 + 卡片 + 行间分隔线。
///
/// 分隔线左缩进对齐**文字**（跳过图标圆），而不是从卡片最左边开始 ——
/// 后者会把图标列切断，看着像两个控件。
struct SettingsGroup<Content: View>: View {

    var title: String?

    /// 卡片下方的灰色说明段（上一代实现同款：「由你自己的代理客户端执行拦截…」）。
    /// nil = 不显示。
    var footnote: String?

    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.app(13))
                    .foregroundStyle(Color.ncTextSecondary)
                    // 标题相对卡片边缘再缩进一点（上一代实测约 4pt）——
                    // 注意调用方已经给整组加过 page 边距，这里不能再加 page。
                    .padding(.horizontal, 4)
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                Color.ncCard.opacity(1),
                in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            )

            if let footnote {
                Text(footnote)
                    .font(.app(13))
                    .foregroundStyle(Color.ncTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

/// 分组内的分隔线。
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, Tokens.Size.rowSeparatorInset)
    }
}

// MARK: - 便捷取值

extension Color {
    /// 便捷读取当前主题强调色。
    ///
    /// **只在拿不到环境值的地方用**（例如 `Toggle.tint`）。
    /// 视图体内优先用 `@Environment(\.themeAccent)` ——
    /// 静态读取不会让视图随主题变化重新求值。
    @MainActor
    static var themeAccentValue: Color { ThemeStore.shared.accent }
}
