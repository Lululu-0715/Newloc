import SwiftUI
import UIKit

/// 玻璃染色的**最大**浓度（染色滑杆 100 时染色填充的不透明度上限）。
///
/// 滑杆「玻璃染色」0~100 直译到 0~0.85：0 = 不染色，100 = 较实。
/// 内部可见（非 private）：CircleIconButton 的圆钮也按滑杆算浓度。
let glassMaxConcentrationOpacity: Double = 0.85

/// 「通透」段的右端（滑杆 0 ~ 0.33 用 `Glass.clear`）。
private let nativeClearUpperBound: Double = 0.33

/// 「标准」段的右端（滑杆 0.33 ~ 0.66 用 `Glass.regular`）。
private let nativeRegularUpperBound: Double = 0.66

/// 滑杆拉到 **100** 时，中性压实层的浓度上限（不透明度）。
///
/// **2026-10-15 用户拍板改成白色**，浓度上限随之由 0.40 提到 **0.90**（提高的
/// 理由见本段末尾，常量本身在 `glassCompactionCeilingOpacity`）。
/// 此前压实色是 `Color.primary`
///（浅色下近黑），滑杆拉到 100 时整块玻璃发暗、在薄荷绿主题下变成一块脏
/// 深绿板 —— 用户要的是「**白色的实**」，不是「黑的实」，原话：
/// 「我要白色的实，不要灰色黑色的实」。
/// 深色模式下 `Color.primary` 本来就是白，所以这次只改了浅色模式那一半，
/// 深色模式观感不变。
///
/// ⚠️ **白比黑"轻"**：浅色底上叠白的可见差天生比叠黑小（同一浓度下实测
/// 亮度差 24 : 76~88），所以上限从 0.40 一路提到 **0.90** —— 照搬 0.40
/// 会看着不够实。0.90 的依据：白色 0.70 时 `50 → 100` 的逐像素差只有
/// `6.78`（0.33 以上只剩白浓度在变、模糊不再变），用户看过实测后要求再加，
/// 提到 0.90 观感才够"实"。
/// 更早还试过 `Color(.systemBackground)`（浅色下就是白）配 0.40，实测
/// `meanDiff` 只有 4.26、肉眼不分档；那次失败的原因是**浓度太低**，
/// 不是"白不行"，别再把结论记成后者。
private let glassCompactionCeilingOpacity: Double = 0.90

/// 玻璃透明度滑杆 → **中性压实浓度**的三段线性插值。
///
/// iOS 26 的原生 `Glass` 只有 `clear` / `regular` / `identity` 三个固定风格档，
/// **没有任何连续「厚度」参数**（本机 SDK 头文件实读）。要给用户一根连续滑杆，
/// 就得自己把「风格档」和「中性压实浓度」两件事拼起来 —— 这张表就是那条曲线：
///
/// 曲线**形状**不变，只是整体按上限浓度缩放 —— 三段的比例是
/// `0 / 0.15 / 0.45 / 1.00 × 上限`（0.40 那一版正是这条式子）：
///
/// | 滑杆 | 玻璃风格 | 压实浓度（旧上限 0.40） | 压实浓度（当前上限 0.90） |
/// |------|----------|------------------------|------------------------|
/// | 0.00 | `.clear`   | 0.000 | 0.000 |
/// | 0.33 | `.clear`   | 0.060 | 0.135 |
/// | 0.66 | `.regular` | 0.180 | 0.405 |
/// | 1.00 | `.regular` | 0.400 | 0.900 |
///
/// 压实色是 **白**（`Color.white`），理由与浓度上限的来历见
/// `glassCompactionCeilingOpacity`。
///
/// ⚠️ 已知边界：0.33 处 `.clear → .regular` 是系统两档玻璃的切换，会有一次
/// 可见跳变 —— 这是原生玻璃的固有粒度，压实曲线只能把两侧的"浓度差"接平，
/// 接不掉系统风格本身的差。实测时这一段要单独出图确认可接受。
private func nativeCompactionOpacity(for transparency: Double) -> Double {
    let t = min(max(transparency, 0), 1)
    let ceiling = glassCompactionCeilingOpacity
    if t < nativeClearUpperBound {
        return ceiling * 0.15 * (t / nativeClearUpperBound)
    }
    if t < nativeRegularUpperBound {
        let local = (t - nativeClearUpperBound) / (nativeRegularUpperBound - nativeClearUpperBound)
        return ceiling * (0.15 + 0.30 * local)
    }
    let local = (t - nativeRegularUpperBound) / (1 - nativeRegularUpperBound)
    return ceiling * (0.45 + 0.55 * local)
}

/// 玻璃容器：**iOS 26 走原生液态玻璃，iOS 15 ~ 18 走自绘降级**。
///
/// ## iOS 26：原生（与上一代实现同构）
///
/// **2026-10-14 纠正 —— 推翻此前「上一代主界面全是自绘」的记载。**
/// 读上一代源码实锤（`Shared/GlassCard.swift` 的 `MapGlassSurfaceModifier`，
/// commit `df64ba0` = 1.0.20 / build 23）：iOS 26 且**非嵌套**时走的是
///
/// ```swift
/// content.glassEffect(Glass.regular.interactive().tint(...), in: shape)
/// ```
///
/// 主界面搜索框 / 三颗浮标 / 底部大卡 / 图层菜单全是 `nested: false`，
/// 也就是**真玻璃**。此前那句「实锤自绘」只看进了同一个 modifier 的
/// `nested` 分支（贴玻璃的小胶囊，不能叠玻璃那一档），漏了 `else`。
///
/// 用户在上一代实现上看到的**按下放大、点击发光、按住拖拽像液体**，
/// 全部来自 `.interactive()` —— 玻璃自身对触摸的响应。自绘做不出这三样：
/// `Material` 只有高斯模糊 + 饱和度提升 + 亮度微调，**没有位移**，
/// 所以既不会有折射，也不会有触摸形变。
///
/// ## 两条轴：染色 与 透明度（2026-10-15 定稿）
///
/// `Glass.tint(_:)` **只接受一个颜色**，而我们要同时表达两件事：
///   - **染色**（`glassOpacity` 滑杆 / 固定 `tint`）→ 颜色层；
///   - **透明度**（`glassTransparency` 滑杆）→ 玻璃多实。
///
/// 2026-10-14 那版把它们写成 if-else 优先级链（染色 > 固定染色 > 厚重压实），
/// 主界面所有落点都传了染色，**压实那一层永远走不到** —— 用户实测
/// 「玻璃透明度这条轴 100% 无效」。现在两层**按 alpha 合成成一个颜色**
/// 再交给系统（见 `composite`），两条轴才真正独立。
///
/// ## iOS 15 ~ 18：自绘降级
///
/// 三层：磨砂材质、染色填充、亮边描边。垫在 `background` 层、不参与触摸。
/// 材质固定「通透」档那两档（非嵌套 `.ultraThin`、嵌套 `.regular`），
/// 「多实」由滑杆调这一层的不透明度表达 —— 三档档位器 2026-10-15 已删。
///
/// ## 嵌套玻璃（两条路一致）
///
/// 贴在另一块玻璃上的小件（`nested: true`）**不能**再叠一层玻璃：
/// 外层会把内层吃掉（上一代实现 1.0.10 踩过，底部面板的主按钮整块变透明）。
/// 所以这一档在两套实现里都退回「淡色填充 + 一圈亮边」，
/// 玻璃感交给外层面板。
struct GlassContainer<Content: View>: View {

    var cornerRadius: CGFloat = Tokens.Radius.sheet

    /// 玻璃染色。传 nil 走中性材质（无渐变主题）。
    var tint: Color?

    /// 这一层是不是**贴在另一块玻璃/卡片上**（卡内小件）：
    /// 材质升为 `regular`、描边更亮，避免与母层糊在一起。
    var nested: Bool = false

    /// 主界面悬浮件标记（圆钮/搜索框/大卡）：亮边更亮更粗。
    /// **只在 iOS 15 ~ 18 的自绘档起作用** —— 原生玻璃的高光由系统画。
    var prominent: Bool = false

    /// **滑杆驱动染色**的基色（不带透明度；浓度 = 滑杆值 × 上限，实时算）。
    /// 传了它就不读 `tint` —— 滑杆 0 = 纯玻璃，往右拉逐渐染成主题色变实。
    /// 基色来自 `ThemeStore.glassTintBase`：**彩色渐变主题 = 主题首色，
    /// 无渐变主题（黑白极简 / 经典蓝白）= nil（整条轴对它们不生效）**。
    var adjustableTint: Color? = nil

    /// 订阅显示偏好：两条玻璃滑杆一动，所有挂着玻璃的界面立即重画。
    @ObservedObject private var prefs = DisplayPreferences.shared

    /// 嵌套档要取主题胶囊填充（与上一代实现同一个 `innerCapsuleFill`）。
    @StateObject private var themeStore = ThemeStore.shared

    /// 合成颜色时要把 `Color.primary` 这类动态色解析成具体 RGB，
    /// 所以要知道当前是浅色还是深色。它一变 `body` 会重算，结果自动跟上。
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            nativeGlass
        } else {
            legacyGlass
        }
    }

    // MARK: - iOS 26：原生液态玻璃

    /// 非嵌套 → 原生 `glassEffect` + `.interactive()`；
    /// 嵌套 → 淡色填充 + 亮边（不能再叠玻璃）。
    ///
    /// `.contentShape(shape)` 是上一代实现 1.0.11 补的一条：玻璃若只画在
    /// `background` 里就**不扩大命中区**，浮层空白处的点击会穿透到地图，
    /// 被地图当成一次选点。显式定形之后，浮层范围内的空白由浮层吃掉。
    /// 标注 `@available` 而不是只靠 `body` 里的 `if #available`：Swift 的
    /// 可用性检查**不跨函数边界**，写在 `body` 的 `if` 里对本属性无效，
    /// 编译器仍会报 `glassEffect` / `Glass` 只在 iOS 26 起可用。
    @available(iOS 26.0, *)
    @ViewBuilder
    private var nativeGlass: some View {
        if nested {
            content
                .background {
                    ZStack {
                        shape.fill(themeStore.innerCapsuleFill)
                        // 装饰描边：留在背景层，天然不参与命中测试。
                        shape.stroke(Color.white.opacity(strokeOpacity), lineWidth: 1)
                    }
                }
                .contentShape(shape)
        } else {
            // ⚠️ `.interactive()` 原样保留 —— 2026-10-14 用户拍板
            // 「按压/放大这条线暂时不动」，后续改动都只碰染色与厚度。
            content
                .glassEffect(nativeGlassStyle.tint(nativeTint).interactive(), in: shape)
                .contentShape(shape)
        }
    }

    /// 原生玻璃的**风格档**：滑杆 0.33 以下 = `.clear`（最透），以上 = `.regular`。
    ///
    /// 连续的那一段由 `nativeCompactionOpacity` 补，见 `nativeTint`。
    @available(iOS 26.0, *)
    private var nativeGlassStyle: Glass {
        prefs.glassTransparency < nativeClearUpperBound ? .clear : .regular
    }

    /// iOS 26 原生玻璃的染色 —— 「染色层」与「压实层」**合成后的单色**。
    ///
    /// nil = 完全不染（纯系统中性玻璃）。两条轴都没量时就是 nil。
    private var nativeTint: Color? {
        var layers: [Color] = []

        // 上层：染色。滑杆驱动的优先于固定主题染色。
        if let adjustableTint, prefs.glassOpacity > 0 {
            layers.append(adjustableTint.opacity(prefs.glassOpacity * glassMaxConcentrationOpacity))
        } else if let tint {
            layers.append(tint.opacity(Tokens.Glass.themedTint))
        }

        // 下层：中性压实。滑杆 0 时浓度为 0，等于不加这一层。
        //
        // 颜色是**白**，不是 `Color.primary`（后者浅色模式下是黑）——
        // 2026-10-15 用户拍板「要白色的实，不要灰色黑色的实」，
        // 来历与上限浓度见 `glassCompactionCeilingOpacity`。
        let compaction = nativeCompactionOpacity(for: prefs.glassTransparency)
        if compaction > 0 {
            layers.append(Color.white.opacity(compaction))
        }

        return composite(layers, in: colorScheme)
    }

    // MARK: - 颜色合成

    /// 把若干层半透明色按 alpha **从下往上**合成成一层等效单色。
    ///
    /// 数组顺序：`layers[0]` 在最上，`layers.last` 在最下。
    ///
    /// **为什么非得合成**：`Glass.tint(_:)` 只吃一个 `Color`，而滑杆给的压实
    /// 与用户调的染色是两层独立的量。写成 if-else 优先级链的后果 2026-10-14
    /// 已经实测过 —— 染色一旦非空，压实永远轮不到。
    private func composite(_ layers: [Color], in scheme: ColorScheme) -> Color? {
        guard var base = layers.last else { return nil }
        for layer in layers.dropLast().reversed() {
            base = over(layer, base, in: scheme)
        }
        return base
    }

    /// `top` 盖在 `under` 之上：
    ///   `A = a₁ + a₂(1 − a₁)`，`C = (C₁a₁ + C₂a₂(1 − a₁)) / A`
    private func over(_ top: Color, _ under: Color, in scheme: ColorScheme) -> Color {
        let t = components(of: top, in: scheme)
        let u = components(of: under, in: scheme)

        let alpha = t.a + u.a * (1 - t.a)
        guard alpha > 0 else { return .clear }

        let factor = u.a * (1 - t.a)
        return Color(.sRGB,
                     red: (t.r * t.a + u.r * factor) / alpha,
                     green: (t.g * t.a + u.g * factor) / alpha,
                     blue: (t.b * t.a + u.b * factor) / alpha,
                     opacity: alpha)
    }

    /// 动态色（`Color.primary` / `.secondary`）**必须先按当前外观解析**才能参与
    /// 数值计算，否则深色模式下会拿着浅色那套分量算，合成出来的颜色是错的。
    ///
    /// `colorScheme` 变化会让 `body` 重算，所以切外观时这里是跟着走的。
    private func components(of color: Color, in scheme: ColorScheme)
        -> (r: Double, g: Double, b: Double, a: Double) {

        let trait = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: trait)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Double(r), Double(g), Double(b), Double(a))
        }
        // 灰度色彩空间没有 RGB 分量，退到白度（黑/白都是这样来的）。
        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &a) {
            return (Double(white), Double(white), Double(white), Double(a))
        }
        return (0, 0, 0, 0)
    }

    // MARK: - iOS 15 ~ 18：自绘降级

    /// 三层自绘：磨砂 + 染色 + 亮边，全部垫在 `background`。
    ///
    /// 刻意不把玻璃放进内容层 —— 老系统上「玻璃吃触摸」的雷点都在那一侧
    /// （`contentShape` 罩住内容行、`onTapGesture` 抢外层按钮），垫底最省事。
    private var legacyGlass: some View {
        content
            .background {
                ZStack {
                    // 磨砂材质：老系统没有原生玻璃，固定用「通透」档那两档材质
                    // （非嵌套 `.ultraThin`、嵌套升两档到 `.regular`）——
                    // 与旧默认档位下的观感一致。「多实」由下面这个不透明度表达。
                    shape
                        .fill(nested ? Material.regular : Material.ultraThin)
                        .opacity(prefs.materialOpacity)

                    // 染色层（上一代 MapGlassSurface 思路：主题色半透明填充）。
                    if let adjustableTint {
                        // 滑杆直映：0 = 不染色，100 = 烧进 0.85 的染色基色。
                        if prefs.glassOpacity > 0 {
                            shape.fill(adjustableTint
                                .opacity(prefs.glassOpacity * glassMaxConcentrationOpacity))
                        }
                    } else {
                        if let tint {
                            shape.fill(tint.opacity(Tokens.Glass.themedTint))
                        }
                        // ⚠️ **这里刻意不再按 `glassOpacity` 叠中性层**（2026-10-15 审查 A8）。
                        //
                        // 无渐变主题（黑白极简 / 经典蓝白）走的是本分支。设置页那边
                        // `isTintAvailable == (glassTintBase != nil)` 为 false，染色滑杆、
                        // 两个步进钮、**「恢复默认」**全被 `.disabled` —— 这一页对用户的
                        // 说法是「当前主题不使用玻璃染色」。
                        //
                        // 但本分支原先仍会按盘里留下的 `glassOpacity` 叠一层
                        // `Color(.systemBackground)`：用户先用彩色主题把染色拉高、再切到
                        // 黑白极简，老值在 iOS 15~18 上**照样改玻璃**，而且因为控件全灰了，
                        // 他连调回去的地方都没有 —— 设置项「说不可用却仍生效且不可改」。
                        //
                        // iOS 26 的 `nativeTint` 本来就只在 `adjustableTint` 非空时
                        // 才吃滑杆，两条实现至此口径一致。
                    }

                    // 亮边描边：画出可点区域（上一代浮标亮圈同款）。
                    shape.stroke(Color.white.opacity(strokeOpacity),
                                 lineWidth: strokeRadius)
                }
            }
    }

    private var strokeOpacity: Double {
        nested ? 0.45 : (prominent ? 0.42 : 0.3)
    }

    private var strokeRadius: CGFloat {
        nested ? 1 : (prominent ? 1 : 0.5)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

// MARK: - 便捷修饰

extension View {

    /// 把视图包进玻璃容器（参数见 `GlassContainer`）。
    func glassContainer(cornerRadius: CGFloat = Tokens.Radius.sheet,
                        tint: Color? = nil,
                        nested: Bool = false,
                        prominent: Bool = false,
                        adjustableTint: Color? = nil) -> some View {
        GlassContainer(cornerRadius: cornerRadius,
                       tint: tint,
                       nested: nested,
                       prominent: prominent,
                       adjustableTint: adjustableTint) {
            self
        }
    }
}
