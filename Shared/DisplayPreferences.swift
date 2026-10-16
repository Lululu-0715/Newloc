import SwiftUI
import Foundation

/// 显示偏好：语言覆盖 / 字体大小 / 玻璃（染色 · 透明度）。
///
/// 「玻璃」是两条**互相正交**的轴（2026-10-14 用户拍板拆开）：
///   - **玻璃染色**（`glassOpacity`）：主题色往玻璃上叠多厚 —— 调颜色；
///   - **玻璃透明度**（`glassTransparency`）：玻璃本身多实 —— 调厚度。
/// 之前只有前者且叫「玻璃浓度」，与后者名字撞车，已改名。
///
/// **2026-10-15 两处简化（用户拍板）**：
///   1. 「玻璃透明度」的**三档档位器删除**，全系统统一成一根连续滑杆。
///      档位与滑杆说的本来是同一件事，摆两套控件等于要用户先挑一套用 ——
///      真正的原因是它在 iOS 26 上还掺了「原生玻璃只有固定风格档」的限制，
///      UI 上就露了出来。现在限制收进 `GlassContainer`，界面只留一条滑杆。
///   2. 「按压反馈」**固定为上一代实现同款「放大回弹」**，设置入口移除；
///      曾短暂存在的「按压光晕」三档（2026-10-16 晨）同日删除 —— 实测
///      主按钮在 iOS 26 上走原生玻璃吃不到它，观感割裂，维持原生。
///
/// 语言与字号要求**改动立即作用于全树** —— 工程里的文字与字号大多是
/// 构建时求值的（`AppLocalization.string` / `Font.app`），不是环境驱动的。
/// 所以刷新机制统一走「根重建」：任何一项变更 `revision` +1，
/// `NewlocApp` 把它接到根视图 `.id(revision)` 上，整棵树推倒重画。
@MainActor
final class DisplayPreferences: ObservableObject {

    static let shared = DisplayPreferences()

    // MARK: - 语言

    enum Language: String, CaseIterable, Identifiable {
        case system
        case simplified = "zh-Hans"
        case traditional = "zh-Hant"
        case english = "en"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return AppLocalization.string("跟随系统")
            // 语言名永远用它自己的语言写，切过去才认得出来。
            case .simplified: return "简体中文"
            case .traditional: return "繁體中文"
            case .english: return "English"
            }
        }

        /// 交给 Bundle 查找的 lproj 名；`nil` = 跟随系统。
        var languageCode: String? {
            switch self {
            case .system: return nil
            case .simplified, .traditional, .english: return rawValue
            }
        }
    }

    // MARK: - 字体大小

    enum FontSize: String, CaseIterable, Identifiable {
        case small
        case standard
        case large
        case extraLarge

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .small: return AppLocalization.string("小")
            case .standard: return AppLocalization.string("标准")
            case .large: return AppLocalization.string("大")
            case .extraLarge: return AppLocalization.string("特大")
            }
        }

        /// 全局字号缩放系数（`Font.app` 乘这个值）。
        var scale: CGFloat {
            switch self {
            case .small: return 0.85
            case .standard: return 1.0
            case .large: return 1.15
            case .extraLarge: return 1.3
            }
        }
    }

    // MARK: - 玻璃染色

    /// 染色滑杆范围与默认值。
    ///
    /// 语义（2026-10-14 定稿）：0 = 不染色（纯磨砂玻璃），100 = 主题色烧到
    /// 最大 0.85 —— 调的是**颜色层多厚**，不是玻璃透不透。
    /// 那条轴在「玻璃透明度」里（`glassTransparency`）。
    /// 默认 0：不染色。历史默认 0.55（更早）与 0.45（2026-10-14 晨）都算
    /// 「用户没动过滑杆」，迁移到 0（动过的值必然 ≠ 这两个数，不误伤）。
    static let glassOpacityRange: ClosedRange<Double> = 0.0...1.0
    static let defaultGlassOpacity: Double = 0.0
    /// 「恢复默认」按钮给的染色值（2026-10-15 用户拍板：30）。
    ///
    /// ⚠️ 与**新装初始默认**（`defaultGlassOpacity` = 0）不是一回事 ——
    /// 用户明确要求只改按钮行为，初始值不动。
    static let resetGlassOpacity: Double = 0.30
    /// 历史默认值。迁移判据：等于其中之一 = 用户没动过滑杆。
    static let legacyDefaultGlassOpacity: [Double] = [0.55, 0.45]

    /// 染色滑杆的**整数百分数**。
    ///
    /// **一级菜单与二级页必须调这一个函数。** 2026-10-15 用户发现「二级页显示 50、
    /// 一级菜单显示 49」—— 根因就是两处取整方式不同：一级用 `Int()` **截断**、
    /// 二级用 `.rounded()` **四舍五入**，滑杆停在 0.4999… 时必然差 1。
    /// 抽成一处之后不会再分叉。
    static func glassOpacityPercent(_ value: Double) -> Int {
        let range = glassOpacityRange
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Int((fraction * 100).rounded())
    }

    /// 玻璃透明度滑杆的整数百分数（与染色那条**同一套取整规则**）。
    ///
    /// 抽出来是为了让「一级/二级显示不一致」这类问题不可能再发生第二次 ——
    /// 两条轴各写一遍 `Int()` 和 `.rounded()` 就是 50 / 49 的成因。
    static func glassTransparencyPercent(_ value: Double) -> Int {
        let range = glassTransparencyRange
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Int((fraction * 100).rounded())
    }

    // MARK: - 玻璃透明度

    /// 玻璃透明度滑杆范围与默认值。
    ///
    /// 语义（2026-10-15 定稿）：**0 = 最透，1 = 最实** —— 调的是玻璃本身多厚。
    /// iOS 26 上由 `GlassContainer` 拆成「风格档（`Glass.clear` / `.regular`）+
    /// 中性压实浓度」两件事近似；iOS 15 ~ 18 上直接映射材质层不透明度。
    ///
    /// 默认 0.30：落在「通透」那一段 —— 旧版本的默认档位就是通透，
    /// 换成滑杆之后默认观感不该变。
    static let glassTransparencyRange: ClosedRange<Double> = 0.0...1.0
    static let defaultGlassTransparency: Double = 0.30

    /// 「恢复默认」按钮给的透明度值（2026-10-15 用户拍板：50）。
    /// 与新装初始默认（0.30）不是一回事 —— 见 `resetGlassOpacity` 的说明。
    static let resetGlassTransparency: Double = 0.50

    /// 旧三档档位 → 新滑杆值的折算表（通透 / 标准 / 厚重）。
    ///
    /// 三档档位器 2026-10-15 删除，盘里存过档位的老用户按这张表迁移 ——
    /// 不然设置会静默回退成默认，用户以为「我的设置被吃了」。
    static let legacyTierTransparency: [Double] = [0.30, 0.66, 1.0]

    /// 旧滑杆（材质层不透明度）的默认值。
    ///
    /// 只用于**注释与测试说明**，不再参与迁移判断 —— 见下面对 `init` 的说明：
    /// 拿「值等于 1.0」当"没动过"的判据会把**用户真的拉到最实**也一并吃掉，
    /// 下次启动又退回 30%，等于设置自己会变。
    static let legacyDefaultGlassTransparency: Double = 1.0

    /// iOS 15 ~ 18 自绘档：材质层不透明度的下限。
    ///
    /// 不设 0：玻璃全透明就不再是玻璃了（连描边圈内的"表面"都没了），
    /// 留一个下限让「最透」仍然是一块看得见的玻璃。
    static let minMaterialOpacity: Double = 0.4

    /// 材质层的实际不透明度（`GlassContainer` 的 iOS 15 ~ 18 分支用）。
    var materialOpacity: Double {
        Self.minMaterialOpacity
            + (1 - Self.minMaterialOpacity) * glassTransparency
    }

    // MARK: - 按压反馈

    /// 全局按压反馈固定为上一代实现同款「放大回弹」。
    ///
    /// 2026-10-14 曾是设置项（放大 / 缩小两档，后者是 iOS 26 原生玻璃控件的手感）；
    /// **2026-10-15 用户拍板收敛成固定一档**：入口删掉、盘里选过「缩小回弹」的
    /// 旧值一并覆盖，所以这里不再需要 `@Published` 状态。
    /// 参数原样取自上一代实现二进制（`response 0.26 / damping 0.6`），不动。
    static let pressFeedbackAnimation: Animation =
        .spring(response: 0.26, dampingFraction: 0.6, blendDuration: 0)

    /// 已废弃的按压反馈存盘键。只用于清理，不再读写。
    static let legacyPressFeedbackKey = "displayPressFeedback"

    private enum Key {
        static let language = "displayLanguage"
        static let fontSize = "displayFontSize"
        static let glassOpacity = "displayGlassOpacity"
        static let glassTransparency = "displayGlassTransparency"
        /// 已废弃：三档档位器删除后只用于迁移，读完即清。
        static let legacyGlassMaterialTier = "displayGlassMaterialTier"
    }

    private let defaults: UserDefaults

    /// 根重建信号。语言 / 字号任何一项变更都 +1。
    @Published private(set) var revision: Int = 0

    @Published var language: Language {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Key.language)
            AppLocalization.setOverrideLanguage(language.languageCode)
            bumpRevision()
        }
    }

    @Published var fontSize: FontSize {
        didSet {
            guard fontSize != oldValue else { return }
            defaults.set(fontSize.rawValue, forKey: Key.fontSize)
            bumpRevision()
        }
    }

    /// 玻璃染色浓度（0 = 纯磨砂；100 = 烧进 0.85 的主题色）。
    ///
    /// 名字里的「染色」是要紧的：它调的是**颜色层**叠多厚，不是玻璃透不透。
    /// 2026-10-14 之前它叫「玻璃浓度」，与「玻璃透明度」混在一起
    /// 分不清，已改名。
    @Published var glassOpacity: Double {
        didSet {
            guard glassOpacity != oldValue else { return }
            defaults.set(glassOpacity, forKey: Key.glassOpacity)
            // 浓度走环境观察（GlassContainer 直接读），不需要整树重建。
        }
    }

    /// 玻璃透明度（0 = 最透、1 = 最实）。
    ///
    /// 2026-10-15 之前它是「磨砂档位 + 材质层浓度」两件套里的后一件，
    /// 现在档位器已删，它就是这根轴的全部。
    @Published var glassTransparency: Double {
        didSet {
            guard glassTransparency != oldValue else { return }
            defaults.set(glassTransparency, forKey: Key.glassTransparency)
        }
    }

    /// 全局字号缩放系数（`Font.app` 用）。
    var fontScale: CGFloat { fontSize.scale }

    private func bumpRevision() {
        revision += 1
    }

    // MARK: - 初始化

    /// 读数值偏好。
    ///
    /// ⚠️ 必须经 `NSNumber` 再取 `doubleValue`：直接写
    /// `defaults.object(forKey:) as? Double`，当底层 NSNumber 装的是
    /// Float 或 Int 时会**静默失败**（Swift 的 NSNumber 桥接严格比对底层
    /// 类型），滑杆就永远读成默认值、看着像"没生效"。
    /// 2026-10-14 实测踩到过：用 `defaults write -float` 写进去的 1.0
    /// 读出来是 nil。
    ///
    /// 顺带兼容字符串形式（命令行 / 启动参数注入的值是字符串）。
    /// 做成 `static` 是因为要在 `init` 里调 —— 那一刻 self 还没构造完。
    private static func storedDouble(_ key: String, in defaults: UserDefaults) -> Double? {
        if let number = defaults.object(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        return defaults.string(forKey: key).flatMap(Double.init)
    }

    /// 读整数偏好（理由同 `storedDouble`）。
    private static func storedInt(_ key: String, in defaults: UserDefaults) -> Int? {
        if let number = defaults.object(forKey: key) as? NSNumber {
            return number.intValue
        }
        return defaults.string(forKey: key).flatMap(Int.init)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedLanguage = defaults.string(forKey: Key.language) ?? Language.system.rawValue
        let resolvedLanguage = Language(rawValue: storedLanguage) ?? .system
        language = resolvedLanguage
        if resolvedLanguage.rawValue != storedLanguage {
            defaults.set(resolvedLanguage.rawValue, forKey: Key.language)
        }
        AppLocalization.setOverrideLanguage(resolvedLanguage.languageCode)

        let storedFontSize = defaults.string(forKey: Key.fontSize) ?? FontSize.standard.rawValue
        let resolvedFontSize = FontSize(rawValue: storedFontSize) ?? .standard
        fontSize = resolvedFontSize
        if resolvedFontSize.rawValue != storedFontSize {
            defaults.set(resolvedFontSize.rawValue, forKey: Key.fontSize)
        }

        let storedOpacity = Self.storedDouble(Key.glassOpacity, in: defaults)
        var resolvedOpacity = storedOpacity.map {
            min(max($0, Self.glassOpacityRange.lowerBound), Self.glassOpacityRange.upperBound)
        } ?? Self.defaultGlassOpacity
        // 历史默认迁移：存的正是某个历史默认值 = 滑杆从没被用户动过，
        // 跟上新默认（0 = 纯玻璃）。动过的值必然不在表里，不会被误伤。
        if Self.legacyDefaultGlassOpacity.contains(resolvedOpacity) {
            resolvedOpacity = Self.defaultGlassOpacity
            defaults.set(resolvedOpacity, forKey: Key.glassOpacity)
        }
        glassOpacity = resolvedOpacity

        // 玻璃透明度：三档档位器已删（2026-10-15）。
        //
        // 迁移判据**只看旧档位键的存在与否**，不看存下来的滑杆值 ——
        // 曾经想过「值等于旧默认 1.0 = 用户没动过」，实测当场被自己抓到：
        // 用户真的把滑杆拉到最实（1.0）时，下次启动会被判成"没动过"
        // 而退回 30%，**设置会自己变**。档位键是旧版独有的，它存在与否
        // 就是"这台机器用过旧体系"的可靠证据，用完即清。
        let storedTier = Self.storedInt(Key.legacyGlassMaterialTier, in: defaults)
        let migratedFromTier = storedTier.flatMap { index in
            Self.legacyTierTransparency.indices.contains(index)
                ? Self.legacyTierTransparency[index]
                : nil
        }
        let storedTransparency = Self.storedDouble(Key.glassTransparency, in: defaults)

        if let migratedFromTier {
            glassTransparency = migratedFromTier
            // 只有真的迁移过才回写，平时不写 —— 回写会把
            // `-displayGlassTransparency 0.5` 这类启动参数落盘，污染下次启动。
            defaults.set(migratedFromTier, forKey: Key.glassTransparency)
            defaults.removeObject(forKey: Key.legacyGlassMaterialTier)
        } else {
            glassTransparency = storedTransparency.map {
                min(max($0, Self.glassTransparencyRange.lowerBound),
                    Self.glassTransparencyRange.upperBound)
            } ?? Self.defaultGlassTransparency
        }

        // 按压反馈：固定放大回弹（2026-10-15 用户拍板）。旧键直接清掉 ——
        // 留着的话下次翻到盘里的 "shrink" 会让人以为这个设置还在。
        // （曾短暂存在的 displayPressGlow 同理，一并清。）
        defaults.removeObject(forKey: Self.legacyPressFeedbackKey)
        defaults.removeObject(forKey: "displayPressGlow")
    }
}

// MARK: - 全局字号

extension Font {

    /// 工程统一字号入口：`Font.app(15)` / `Font.app(15, weight: .semibold)`。
    ///
    /// 与 `.system(size:)` 的唯一区别是乘上「设置 → 字体大小」的缩放系数。
    /// 全工程文字一律走这里，不许再直接写 `.system(size:)`
    ///（否则字号设置对它无效）。
    ///
    /// `design:` 参数系统版要 iOS 16；iOS 15 上只有等宽场景（诊断页），
    /// 用 `.monospaced()` 修饰近似，其余 design 静默忽略。
    @MainActor
    static func app(_ size: CGFloat,
                    weight: Font.Weight? = nil,
                    design: Font.Design? = nil) -> Font {
        let scaled = size * DisplayPreferences.shared.fontScale
        // ⚠️ 必须解包成非可选：`weight: Font.Weight?` 会解析到 iOS 16 才有的
        // 新重载（老重载的 weight 是非可选、默认 .regular）。
        let resolvedWeight = weight ?? .regular

        if let design {
            if #available(iOS 16.0, *) {
                return .system(size: scaled, weight: weight, design: design)
            }
            if design == .monospaced {
                return .system(size: scaled, weight: resolvedWeight).monospaced()
            }
        }
        return .system(size: scaled, weight: resolvedWeight)
    }
}
