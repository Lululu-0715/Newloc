import SwiftUI

/// 一套配色主题。
///
/// 主题由两样东西定义：
///   1. **渐变三色** —— 欢迎页整页背景、图标块与主按钮的色调。**空数组表示不铺渐变**
///      （黑白极简、经典蓝白都属于这一类，它们靠中性色 + 强调色撑场面）；
///   2. **强调色** —— 全局 `.tint`，决定按钮、选中态、图标底色。
///      **`nil` 表示「跟随前景色」**：由 `accent` 用具体动态色实现 ——
///      浅色下解析成近黑，深色下解析成近白，用户切外观时自动重算，
///      不需要任何判断分支（**不能**直接用 `Color.primary` 语义角色 ——
///      见 `accent` 注释里 2026-10-15 的玻璃管线实测）。
///
/// 色值继承自上一版（上一代实现 1.0.16 起彩色整体 ×0.88 压深一档，本工程按压深后的现值保留，
/// 不做二次调色）。「经典蓝白」的 `#007aff` 是系统蓝，属于系统语义，不参与品牌调色。
struct AppTheme: Identifiable, Equatable, Hashable {

    let id: String

    /// 主题名的本地化 key（就是简体中文原文，走 `AppLocalization` 查表）。
    let nameKey: String

    /// 渐变停靠色（左上 → 右下）。空数组表示不铺渐变。
    let gradientHexes: [String]

    /// 强调色。`nil` = 跟随前景色（自动反转）。
    let accentHex: String?

    /// 是否铺渐变。
    var hasGradient: Bool { !gradientHexes.isEmpty }

    /// 是否是「强调色跟随前景色」的主题（即黑白极简）。
    ///
    /// 这个标记决定了整套界面里最关键的几处反转：主按钮变白底黑字、
    /// 设置行的图标圆变白底黑图标、开关打开态变白底黑钮。
    /// **不能靠判断 hex 是否接近黑色来做** —— 那样深色模式下会糊成一片。
    var invertsAccent: Bool { accentHex == nil }

    var displayName: String { AppLocalization.string(nameKey) }

    /// 强调色。
    ///
    /// 「跟随前景色」的解析值：浅色近黑、深色近白，用户切外观时自动重算 ——
    /// 这是黑白主题能成立的关键。写死 `#0A0A0A` 的话，深色模式下就是
    /// 黑底上的黑按钮、黑图标，整个界面糊掉。
    var accent: Color {
        guard let hex = accentHex, let color = Color(hex: hex) else { return Self.followForegroundAccent }
        return color
    }

    /// 「跟随前景色」主题（黑白极简）的强调色 —— **具体动态色，不是语义角色**。
    ///
    /// ⚠️ 2026-10-15 用户实测：iOS 26 的玻璃卡（`glassEffect`）内容合成管线
    /// 会把 `Color.primary`（= UIKit `.label` 语义角色）重映射成低不透明度
    /// 版本，mono 主按钮被洗成 #CCC 灰底白字。同一台模拟器上换成具体 hex
    /// （classic `#007aff`）实测一色不差 —— 填充机制没坏，坏在语义角色被
    /// 玻璃管线重映射。所以这里用 `UIColor` 动态提供者给出**具体 RGB**
    /// （浅色纯黑 / 深色纯白，与 `.primary` 在两种外观下的解析值一致）：
    /// 外观切换照旧自动反转，但玻璃管线动不了它。
    private static let followForegroundAccent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .white : .black
    })

    var gradientColors: [Color] { gradientHexes.compactMap(Color.init(hex:)) }

    /// 整页背景渐变。不铺渐变的主题返回 nil，调用方回落到系统底色。
    var gradient: LinearGradient? {
        let colors = gradientColors
        guard colors.count >= 2 else { return nil }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 图标块 / 主按钮用的渐变。只有一个色值时退回纯色渐变，保证类型稳定。
    var solidGradient: LinearGradient {
        let colors = gradientColors
        guard colors.count >= 2 else {
            return LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
        }
        // 只取前两色：第三个色是收尾的浅色，铺到大按钮上会把白字吃掉
        // （比如「玫红雪白」的 #d5d5d5）。
        return LinearGradient(colors: [colors[0], colors[1]],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 设置页做色卡预览用的渐变（三色全用）。
    var previewGradient: LinearGradient { gradient ?? solidGradient }

    /// 供 `.foregroundStyle` 使用的主按钮填充。
    ///
    /// 黑白主题没有渐变可用，用强调色本身（浅色下近黑、深色下近白）。
    var primaryActionFill: AnyShapeStyle {
        if invertsAccent { return AnyShapeStyle(accent) }
        return AnyShapeStyle(solidGradient)
    }

    /// 主按钮上的文字色：与填充**对立**。
    ///
    /// 黑白主题走 `Color(.systemBackground)`（浅色下白、深色下黑）；
    /// 彩色主题走白色（渐变底色够深，白字始终可读）。
    var onPrimaryAction: Color {
        invertsAccent ? Color(uiColor: .systemBackground) : .white
    }
}

// MARK: - 主题清单

/// 全部可选主题，顺序即设置页里的顺序。
enum ThemeCatalog {

    /// 默认主题。新装用户看到的是黑白极简。
    static let defaultID = "mono"

    static let all: [AppTheme] = [

        // 默认档：不铺渐变、强调色跟随前景色（自动反转）。
        AppTheme(id: "mono",
                 nameKey: "黑白极简",
                 gradientHexes: [],
                 accentHex: nil),

        // 上一版的原样观感：不铺渐变 + 系统蓝。只是名字从「跟随系统」改明确了。
        AppTheme(id: "classic",
                 nameKey: "经典蓝白",
                 gradientHexes: [],
                 accentHex: "#007aff"),

        AppTheme(id: "rose",
                 nameKey: "玫红雪白",
                 gradientHexes: ["#e0364d", "#e08996", "#d5d5d5"],
                 accentHex: "#cc3d54"),

        AppTheme(id: "mint",
                 nameKey: "薄荷孔雀绿",
                 gradientHexes: ["#8ce0ac", "#3ec293", "#009a73"],
                 accentHex: "#008f6b"),

        AppTheme(id: "night",
                 nameKey: "夜紫橙金",
                 gradientHexes: ["#2a1e2f", "#7b5949", "#de932b"],
                 accentHex: "#bf740e"),

        AppTheme(id: "neon",
                 nameKey: "荧光水绿",
                 gradientHexes: ["#33e0d5", "#2bc2a3", "#219a74"],
                 accentHex: "#108f6d"),

        AppTheme(id: "electric",
                 nameKey: "电光蓝紫",
                 gradientHexes: ["#00d8e0", "#257cc3", "#15218b"],
                 accentHex: "#1b68b7"),
    ]

    /// 按 id 取主题，取不到回落到默认。
    ///
    /// 用 id 而不是下标存盘：以后在中间插入一套主题，老用户的选项不会串位。
    static func theme(id: String) -> AppTheme {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - 十六进制解析

extension Color {

    /// 解析 `#rrggbb` / `rrggbb` / `#rgb` / `#rrggbbaa`。
    ///
    /// 写成 `init?` 而不是 `init`：色值全部硬编码在 `ThemeCatalog` 里，
    /// 万一写错一个字符，希望是「这一套退回系统色」，而不是崩在取色值那一行。
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }

        guard let value = UInt64(text, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch text.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
