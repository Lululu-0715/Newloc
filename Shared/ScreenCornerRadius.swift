import UIKit

/// 屏幕**物理圆角**（pt）与地图页大卡片的同心尺寸链。
///
/// 大卡片要跟屏幕圆角**同心** —— 两条弧共圆心 ⟺ 半径差 = 两者间距。
/// 边距取 `Tokens.Spacing.floating`（当前 12），所以「卡片圆角 = 屏幕圆角 − 边距」；
/// 卡片里的内层小卡与主按钮再与卡片同心（卡片圆角 − 内容留边）。
///
/// **为什么全版本实算而不是 iOS 26 的 `ConcentricRectangle`**：
/// 同心是版式约束，不该随系统版本变。实算在 iOS 15~26 上行为完全一致，
/// 也与上一代的做法相同（用户确认沿用）。
///
/// 取值顺序（前一步拿不到才走下一步）：
///   1. 运行时 KVC 读 `UIScreen` 私有属性 `_displayCornerRadius` ——
///      唯一能覆盖所有机型的方式。本工程自签分发，无审核风险。
///   2. 机型表兜底（实机实测汇总）。
///   3. 表里也没有（未来新机型）用 `fallback`（55，在售机型中出现最多）。
///
/// 下限 39：直角屏（SE 等）谈不上同心，按最小圆角屏处理。
enum ScreenCornerRadius {

    /// 屏幕圆角（pt）。
    static var value: CGFloat { resolved }

    /// 机型表和运行时都拿不到时的默认值。
    static let fallback: CGFloat = 55

    /// 圆角下限：直角屏按最小圆角屏处理。
    static let minimum: CGFloat = 39

    private static let resolved: CGFloat = resolve()

    private static func resolve() -> CGFloat {
        if let raw = displayCornerRadius {
            return max(raw, minimum)
        }
        return max(tableRadius(for: deviceIdentifier) ?? fallback, minimum)
    }

    /// 机型表查询（暴露给单测：兜底表漏一行就是重演一次同心 bug）。
    static func tableRadius(for identifier: String) -> CGFloat? {
        knownRadii[identifier]
    }

    /// 私有属性 `_displayCornerRadius`。系统改名 / 被裁剪时返回 nil，交给兜底表。
    ///
    /// 走 `NSNumber` 而不是直接 `as? CGFloat`：KVC 把 CGFloat 装箱成 NSNumber，
    /// 直接转换在部分系统版本上会失败。
    private static var displayCornerRadius: CGFloat? {
        guard let number = UIScreen.main.value(forKey: "_displayCornerRadius") as? NSNumber,
              number.doubleValue > 0 else {
            return nil
        }
        return CGFloat(number.doubleValue)
    }

    private static var deviceIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// 实机实测的屏幕圆角表。只在运行时读不到时才用，不必求全。
    private static let knownRadii: [String: CGFloat] = [
        // 39 —— X 那一代起的第一批圆角屏（含 6.5 吋大号）
        "iPhone10,3": 39, "iPhone10,6": 39,
        "iPhone11,2": 39, "iPhone11,4": 39, "iPhone11,6": 39,
        "iPhone12,3": 39, "iPhone12,5": 39,

        // 41.5 —— XR / 11 的 LCD 屏
        "iPhone11,8": 41.5, "iPhone12,1": 41.5,

        // 44 —— 12 mini / 13 mini
        "iPhone13,1": 44, "iPhone14,4": 44,

        // 47.33 —— 12 / 12 Pro / 13 / 13 Pro / 14 / 16e
        "iPhone13,2": 47.33, "iPhone13,3": 47.33,
        "iPhone14,5": 47.33, "iPhone14,2": 47.33,
        "iPhone15,5": 47.33, "iPhone17,5": 47.33,

        // 53.33 —— 12 Pro Max / 13 Pro Max / 14 Plus
        "iPhone13,4": 53.33, "iPhone14,3": 53.33, "iPhone15,6": 53.33,

        // 55 —— 14 Pro / 14 Pro Max / 15 全系 / 16 / 16 Plus / 17 / 17 Pro Max(Air 代)
        "iPhone15,2": 55, "iPhone15,3": 55, "iPhone15,4": 55,
        "iPhone16,0": 55, "iPhone16,1": 55, "iPhone16,2": 55,
        "iPhone17,3": 55, "iPhone17,4": 55,

        // 62 —— 16 Pro / 16 Pro Max 起的 Pro 系
        "iPhone17,1": 62, "iPhone17,2": 62,
    ]
}

/// 地图页底部大卡片的同心尺寸链 —— **完整复刻上一代实现**（2026-10-12 用户拍板）。
///
///     屏幕圆角 → −12（边距） → 卡片圆角（与屏幕同心） → −(卡片圆角−23) → 内层 23
///
/// 上一代的做法（GlassCard.swift / MapHomeView.swift 原样）：
/// 1. 卡片与屏幕**同心**：卡片圆角 = 屏幕圆角 − 边距；
/// 2. 内容留边**由相切反推**：留边 = 卡片圆角 − 23（23 = 46pt 主按钮的半高，
///    下限 20 兜底老机型）—— 内层圆角正好 23，小卡与按钮和卡片两条弧**相切**，
///    缝处处等宽。这是全链同心的唯一解，留边在大圆角屏上自然偏大
///    （本机 24 / 16 Pro Max 31）—— 用户经历「嫌远→嫌不同心」两轮后确认：
///    **同心的观感优先，接受留边 24**。
/// 3. 边距 = `Tokens.Spacing.floating`（2026-10-14 用户拍板 12；此前 8、
///    上一代与设计稿都是 12 —— 绕一圈回到了原点，但这次只有一个真源）。
/// 4. 内层小卡自身内边距 12（上一代原版）。
///
/// 老机型（屏幕圆角小，算出留边 < 20）：走 20 下限，内层比半高更圆一点点，
/// 同心让位给可读性（上一代同款行为）。
enum PanelMetrics {

    /// 卡片到屏幕外沿的留边。
    ///
    /// **不再是独立常量** —— 直接取 `Tokens.Spacing.floating`。
    /// 这两个数必须是同一个：卡片左右留边和「卡片圆角 = 屏幕圆角 − 留边」
    /// 用的是同一次测量的边距，分家就会出现「卡片贴边了但圆角还是老间距算的」
    /// 那种隐形错位（2026-10-14 之前正是两处各写一个 8）。
    static var edgeInset: CGFloat { Tokens.Spacing.floating }

    /// 主按钮高度。相切档位「23 = 半高」依赖这个值，改高度要同步看 contentInset。
    static let buttonHeight: CGFloat = 46

    /// 内层小卡自身的内边距（上一代原版 12）。
    static let selectionInset: CGFloat = 12

    /// 卡片内容的四周留边：**由相切反推**（卡片圆角 − 按钮半高，下限 20）。
    static var contentInset: CGFloat {
        max(cardRadius - buttonHeight / 2, 20)
    }

    /// 底部大卡片圆角：屏幕圆角 − 边距，与屏幕**同心**。
    /// 本机 62−12=50；16 Pro Max 同为 62 → 也是 50。
    static var cardRadius: CGFloat {
        ScreenCornerRadius.value - edgeInset
    }

    /// 内层小卡 / 主按钮的圆角：与卡片同心、两条弧**相切**。
    /// 正常机型正好 = 23（按钮半高）。
    static var innerRadius: CGFloat {
        max(cardRadius - contentInset, 0)
    }

    /// 主按钮圆角：相切目标值是 innerRadius；老机型走 20 下限分支时
    /// innerRadius 可能超过半高，此时停在半高（胶囊），同心让位给可读性。
    static var buttonRadius: CGFloat {
        min(innerRadius, buttonHeight / 2)
    }
}
