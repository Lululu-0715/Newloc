import SwiftUI

/// 配色主题的存储与派生样式。
///
/// 和「外观」（浅色 / 深色 / 跟随系统）分开管理：那两个是**系统外观**，
/// 这个是**品牌配色**，可以各选各的（深色 + 玫红雪白是合法组合）。
/// 存盘用主题 id 字符串，加新主题不会影响老数据。
@MainActor
final class ThemeStore: ObservableObject {

    static let shared = ThemeStore()

    private enum Key {
        static let themeID = "appThemeID"
    }

    private let defaults: UserDefaults

    @Published var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.id, forKey: Key.themeID)
            AppLog.info("主题", "配色主题已切换", details: ["theme": theme.id])
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.themeID) ?? ThemeCatalog.defaultID
        let resolved = ThemeCatalog.theme(id: stored)
        theme = resolved
        // 盘里存的主题在**这一版**里已经不存在了（比如某套配色被删掉）：
        // `theme(id:)` 会回落到默认，这里把回落结果一并写回盘。
        // 不回写也不会出错（界面读的是内存里的值），但盘里会一直留着一个
        // 取不到的 id —— 数据是脏的，而且永远清不掉。
        if resolved.id != stored {
            defaults.set(resolved.id, forKey: Key.themeID)
        }
    }

    /// 全局强调色。
    var accent: Color { theme.accent }

    /// 是否铺渐变。
    var hasGradient: Bool { theme.hasGradient }

    /// 整页背景渐变（不铺渐变的主题为 nil）。
    var gradient: LinearGradient? { theme.gradient }

    /// 玻璃浮层在 iOS 26 上的染色。
    ///
    /// 有渐变时用主题首色，让浮层带一点主题的色偏 —— 那块胶囊之所以看起来
    /// 「有味道」，靠的就是底色透过玻璃映上来。
    var glassTint: Color {
        guard hasGradient, let first = theme.gradientColors.first else {
            return Color.ncCard.opacity(Tokens.Glass.neutralTint)
        }
        return first.opacity(Tokens.Glass.themedTint)
    }

    /// 原生玻璃滑杆染色的**基色**（不带透明度）。`nil` = 这根轴对当前主题不生效。
    ///
    /// 2026-10-14 拍板：玻璃染色滑杆直映原生玻璃的染色浓度（0 = 纯透镜感，
    /// 100 = 最实），浓度由 `GlassContainer` 按滑杆实时算，这里只出颜色。
    ///
    /// **2026-10-15 收窄：无渐变主题（黑白极简 / 经典蓝白）返回 `nil`。**
    /// 这两套主题的定位就是「中性底 + 一个强调色」，强调色不该扩散到玻璃上。
    /// 此前它们回落到 `Color.primary`（浅色近黑 / 深色近白），用户把染色滑杆
    /// 拉到 50 时，主界面的搜索框 / 三颗浮标 / 底部大卡玻璃会被整体压成一片灰
    /// —— 用户原话「蓝白就是蓝色和白色，黑白就是黑色和白色，不需要把卡片
    /// 搜索框浮标按钮的玻璃上色」。返回 `nil` 时 `GlassContainer` 走中性玻璃。
    ///
    /// ⚠️ 黑白主题这一支更早写的是 `Color.white`（2026-10-14 早些时候），
    /// 当晚实测推翻：浅色模式下叠白 = **完全没有变化**（设置页预览卡
    /// 「滑杆 0 / 100」两张截图逐像素比对，`meanDiff = 0.00`）。
    /// 要的是「更实 / 更浓」就得往**当前外观的反方向**压 —— 但那套补丁现在
    /// 已经不需要了：这两套主题直接不上色。
    var glassTintBase: Color? {
        guard hasGradient, let first = theme.gradientColors.first else { return nil }
        return first
    }

    /// 贴在玻璃面板**内部**的胶囊填充。
    ///
    /// iOS 26 上这层不能再叠一次玻璃（嵌套玻璃会被外层吃掉），所以用一层
    /// 带主题色偏的淡填充代替。无渐变时退回中性灰。
    var innerCapsuleFill: AnyShapeStyle {
        guard hasGradient else {
            return AnyShapeStyle(Color.primary.opacity(Tokens.Glass.neutralCapsule))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: theme.gradientColors.prefix(2).map { $0.opacity(Tokens.Glass.themedCapsule) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// 页面背景渐变的浓度。
    ///
    /// 深色模式下要更浓一点，否则彩色压到黑底上几乎看不出来。
    /// 数值刻意保守：背景上还有正文，染太深会先把可读性搞掉。
    func backgroundOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.42 : 0.30
    }
}

// MARK: - 强调色的环境传递

/// 主题强调色。
///
/// **为什么不用 `Color.accentColor`**：那个静态色读的是资源目录里的 AccentColor，
/// 跟 `.tint()` 完全是两回事。只挂 `.tint()` 的话，自绘的胶囊、图标底色
/// 还是系统蓝 —— 一眼就看出来了。
///
/// **为什么不直接读 `ThemeStore.shared.accent`**：那样叶子视图不会因为主题变化
/// 重新求值（入参没变，SwiftUI 会跳过它的 body）。走环境值最稳：
/// 值一变，**只有真正读了它的视图**重新求值。
private struct ThemeAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    /// 当前主题的强调色。
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }
}

// MARK: - 主题背景

/// 整页主题背景。
///
/// 铺在系统分组底色**之上**：主题只负责染色，不负责提供对比度 ——
/// 正文颜色、分隔线、分组卡片全都照旧由系统语义色负责。
struct ThemedBackground: View {

    @StateObject private var themeStore = ThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.ncPage

            if let gradient = themeStore.gradient {
                gradient
                    .opacity(themeStore.backgroundOpacity(for: colorScheme))
                    // 顶部浓、往下淡：标题区染上主题色，长列表区域保持干净。
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white.opacity(0.75), location: 0.45),
                                .init(color: .white.opacity(0.35), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .ignoresSafeArea()
    }
}
