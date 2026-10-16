import SwiftUI

/// 设计令牌：全工程唯一的尺寸来源。
///
/// **为什么尺寸也要集中**：散落在各个视图里的魔法数字，改一处漏一处 ——
/// 上一版就是这样把圆角和边距搞成三种取值的。这里只留命名常量，
/// 视图里不允许再出现裸数值。
enum Tokens {

    // MARK: - 圆角

    enum Radius {
        /// 底部悬浮主卡片（也是欢迎页卡片）
        static let sheet: CGFloat = 26
        /// 分组列表卡片（设置页 iOS 26 风格的大圆角，2026-10-13 用户拍板）
        static let card: CGFloat = 20
        /// 按钮、输入框、悬浮小卡
        static let control: CGFloat = 14
        /// 状态胶囊
        static let pill: CGFloat = 10
        /// 圆形按钮
        static let circle: CGFloat = 19
    }

    // MARK: - 间距

    enum Spacing {
        /// 页面左右安全边距。
        ///
        /// 2026-10-14 用户拍板 16 → 20：设置体系（一级「设置」+ 全部二级页）
        /// 统一加宽，卡片不再贴近屏幕边。**只作用于设置体系页面**，
        /// 主界面悬浮件走 `floating`（见下）；设置体系页面走本条。
        static let page: CGFloat = 20
        /// 悬浮元件与屏幕边缘的距离。
        ///
        /// **这是主界面边距的唯一真源**：`PanelMetrics.edgeInset` 由它派生
        /// （同心的「卡片圆角 = 屏幕圆角 − 边距」要用同一个数）。
        ///
        /// 沿革：设计稿（`docs/02` 第 1.1 节）本写 12 → 2026-10-12 用户觉得
        /// 16 Pro Max 上留白偏多，拍板 **8** → 2026-10-14 用户看了一圈又拍板
        /// 改回 **12**（8 太贴边）。改这里就够了，不要再改第二处。
        /// 只作用于主界面（顶部搜索条左右、卡片左右、卡片距底、浮标列贴右）。
        static let floating: CGFloat = 12
        /// 卡片内边距
        static let card: CGFloat = 16
        /// 列表行左右内边距
        static let row: CGFloat = 14
        /// 行内图标与文字之间
        static let rowIcon: CGFloat = 12
        /// 欢迎页左右留白。比常规页面宽 —— 宽留白是这套编辑感版式成立的前提，
        /// 按常规的 16 会把大标题和细线一起挤到边上，气质立刻掉下来。
        static let welcome: CGFloat = 28
    }

    // MARK: - 尺寸

    enum Size {
        /// 设置行左侧圆形图标章（上一代截图实测 36pt，2026-10-13 用户拍板）
        static let settingsIcon: CGFloat = 36
        /// 顶部搜索胶囊高度
        static let searchBar: CGFloat = 44
        /// 圆形浮动按钮直径。
        ///
        /// 与顶部设置圆钮**必须同值** —— 设计稿（`docs/02` 第 1.1 节）写明
        /// 「顶部设置、图层、实时位置三颗都是 44×44 正圆，同一套玻璃」。
        /// 这里曾经是 38，比设置圆钮小一圈，三颗摆在一起肉眼可见地不齐。
        static let floatingButton: CGFloat = 44
        /// 主按钮高度。`PanelMetrics.buttonHeight` 同值 —— 用户拍板保持 46。
        static let primaryButton: CGFloat = 46
        /// 状态胶囊高度
        static let pill: CGFloat = 20
        /// 列表分隔线左缩进：对齐文字，不切断图标
        static var rowSeparatorInset: CGFloat { Spacing.row + settingsIcon + Spacing.rowIcon }
    }

    // MARK: - 材质

    /// 玻璃材质的浓度参数。
    enum Glass {
        /// 有主题时玻璃的染色：让浮层带一点主题色偏。
        /// 压得很低（0.22）——玻璃本身还要负责折射与高光，染重了会退回成一块色板。
        static let themedTint: Double = 0.22
        /// 无渐变色时的中性染色
        static let neutralTint: Double = 0.06
        /// 玻璃面板**内部**胶囊：有主题
        static let themedCapsule: Double = 0.16
        /// 玻璃面板内部胶囊：中性
        static let neutralCapsule: Double = 0.08
        /// 玻璃描边浓度
        static let stroke: Double = 0.12
        // 「玻璃底色浓度」已迁往「设置 → 玻璃透明度」（DisplayPreferences.glassOpacity，
        // 默认 0.55 与旧 surfaceTint 同值），此处不再保留常量以免两处真源。
    }
}

// MARK: - 语义色

/// 中性层级一律走系统语义色，不写死灰阶表。
///
/// **为什么不自己定两套灰阶**：手写「浅色 `#F4F4F4` / 深色 `#0A0A0A`」看着可控，
/// 实际会在「提高对比度」「智能反转」「辅助功能设置」这些场景下与系统脱节 ——
/// 系统色自带这些适配，且在深浅色之间自动切换。
/// 主题系统只负责**染色**与**强调色**，不接管中性层级。
///
/// 命名统一加 `nc` 前缀（Newloc Color），避免与系统同名属性混淆。
extension Color {

    /// 页面底色
    static var ncPage: Color { Color(uiColor: .systemGroupedBackground) }

    /// 卡片 / 分组行底色
    static var ncCard: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    /// 控件填充（输入框、未选中胶囊、次要按钮）
    static var ncFill: Color { Color.primary.opacity(0.06) }

    /// 主文字
    static var ncText: Color { .primary }

    /// 次文字（取值、状态文字）
    static var ncTextSecondary: Color { .secondary }

    /// 三级文字（说明、时间戳）
    static var ncTextTertiary: Color { Color(uiColor: .tertiaryLabel) }

    /// 分隔线
    static var ncSeparator: Color { Color(uiColor: .separator) }
}
