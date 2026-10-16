import SwiftUI

/// 配色主题选择页。
///
/// 版式沿用上一代：顶部一张预览卡 + 下面每套一行
/// （色卡 + 名字 + 等宽 hex + 选中勾）。
struct ThemePickerView: View {

    @StateObject private var themeStore = ThemeStore.shared
    @Environment(\.themeAccent) private var accent

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 24) {
                    previewCard
                    themeList
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("配色主题"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 预览卡

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(themeStore.theme.displayName)
                .font(.app(17, weight: .semibold))
                .foregroundStyle(Color.ncText)

            Text(summary)
                .font(.app(12))
                .foregroundStyle(Color.ncTextSecondary)
                .padding(.top, 4)

            HStack(spacing: 8) {
                swatchStrip(for: themeStore.theme, size: 44)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
        }
        .padding(Tokens.Spacing.card)
        .background(
            Color.ncCard,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        )
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private var summary: String {
        if themeStore.theme.invertsAccent {
            return AppLocalization.string("强调色跟随外观自动反转：浅色模式下近黑，深色模式下近白。")
        }
        if themeStore.theme.hasGradient {
            return AppLocalization.string("彩色渐变主题，界面背景与按钮会带上该色调。")
        }
        return AppLocalization.string("中性底色，强调色固定，观感与上一代一致。")
    }

    // MARK: - 主题列表

    private var themeList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ThemeCatalog.all.enumerated()), id: \.element.id) { index, theme in
                Button {
                    themeStore.theme = theme
                } label: {
                    row(for: theme)
                }
                .buttonStyle(.plain)

                if index < ThemeCatalog.all.count - 1 {
                    Divider().padding(.leading, Tokens.Spacing.row)
                }
            }
        }
        .background(
            Color.ncCard,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        )
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private func row(for theme: AppTheme) -> some View {
        HStack(spacing: 12) {
            swatchStrip(for: theme, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.displayName)
                    .font(.app(16))
                    .foregroundStyle(Color.ncText)

                Text(hexSummary(for: theme))
                    .font(.app(11, design: .monospaced))
                    .foregroundStyle(Color.ncTextTertiary)
            }

            Spacer(minLength: 0)

            if themeStore.theme.id == theme.id {
                Image(systemName: "checkmark")
                    .font(.app(14, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, Tokens.Spacing.row)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: - 色卡

    /// 三色色卡。
    ///
    /// 无渐变主题（黑白极简 / 经典蓝白）也要有色卡 —— 否则列表里会出现
    /// 一块空白，看着像没加载出来。用「强调色 + 中性灰 + 强调色」拼一条，
    /// 信息量够表达「这套是以强调色为主的」。
    private func swatchStrip(for theme: AppTheme, size: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(swatchColors(for: theme).enumerated()), id: \.offset) { _, color in
                color
            }
        }
        .frame(width: size * 3 + 4, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func swatchColors(for theme: AppTheme) -> [Color] {
        if theme.hasGradient {
            // 补齐到三格：个别主题色值写错时 `compactMap` 会少一个，
            // 补上强调色免得色卡缺一块。
            var colors = theme.gradientColors
            while colors.count < 3 { colors.append(theme.accent) }
            return Array(colors.prefix(3))
        }
        return [theme.accent, Color.primary.opacity(0.28), theme.accent]
    }

    /// 主题行的副标题：色值摘要。
    ///
    /// ⚠️ 没写 hex 的主题（黑白极简：`accentHex == nil`，强调色跟随前景色自动反转）
    /// **不能**把内部的 `Color.primary` 常量名当文案吐出来 —— 那会让用户看到一个
    /// 像没做完的英文占位符，而同排其它主题显示的都是 `#e0364d` 这种真 hex
    ///（2026-10-15 审查 B5）。
    private func hexSummary(for theme: AppTheme) -> String {
        if theme.hasGradient {
            return theme.gradientHexes.joined(separator: " ")
        }
        return theme.accentHex ?? AppLocalization.string("强调色随外观反转")
    }
}
