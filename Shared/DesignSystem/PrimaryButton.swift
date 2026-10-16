import SwiftUI

/// 主操作按钮。
///
/// 黑白主题下是「浅色模式：近黑底 + 近白字」，深色模式自动翻成
/// 「近白底 + 近黑字」—— 靠的是主题的 `primaryActionFill` 与
/// `onPrimaryAction` 这一对动态色，这里**不需要写任何外观判断**。
///
/// 彩色主题走渐变底 + 白字（渐变够深，白字始终可读）。
struct PrimaryButton: View {

    let title: String
    var systemImage: String?
    var isLoading: Bool = false
    var isEnabled: Bool = true
    /// 按钮高度。默认取令牌值；嵌在卡片里时传更小的值。
    var height: CGFloat = Tokens.Size.primaryButton
    /// 圆角。嵌在玻璃大卡片里时传 `PanelMetrics.innerRadius`（与卡片同心）；
    /// 默认走通用档位。
    var cornerRadius: CGFloat = Tokens.Radius.control
    /// 是否嵌在**玻璃表面内部**（如主界面底部大卡）。
    /// 玻璃卡内再套 .glassProminent 就是玻璃叠玻璃（HIG 禁忌），所以
    /// iOS 26 上这一档改用实底填充（同 Apple 地图卡内的方向按钮）。
    var embeddedInGlass: Bool = false
    let action: () -> Void

    @StateObject private var themeStore = ThemeStore.shared

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *), !embeddedInGlass {
            // iOS 26：**系统原生玻璃主按钮**（2026-10-14 用户拍板全转原生）。
            // .glassProminent = tint 色实感玻璃 + 系统按压动效（放大回弹、
            // 触点照亮、流光），文字对比度由系统保证。玻璃合成管线会重映射
            // 语义色，所以 label 不再手写 background/foregroundStyle ——
            // 全部交给系统，黑白主题的近黑强调色经 .tint() 交给玻璃上色。
            Button(action: action) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.app(15, weight: .semibold))
                    }

                    Text(title)
                        .font(.app(17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
            }
            .buttonStyle(.glassProminent)
            .tint(themeStore.theme.accent)
            .disabled(!isEnabled || isLoading)
            .opacity(isEnabled ? 1 : 0.4)
        } else {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(themeStore.theme.onPrimaryAction)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.app(15, weight: .semibold))
                    }

                    Text(title)
                        .font(.app(17, weight: .semibold))
                }
                .foregroundStyle(themeStore.theme.onPrimaryAction)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    themeStore.theme.primaryActionFill,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            // 1.05 对整宽按钮位移太大，放大档收到 1.03。
            .appPressFeedback(growScale: 1.03)
            .disabled(!isEnabled || isLoading)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// 次要按钮：不加实底，用主题强调色写字。
///
/// 外观分三种：
///   - `.filled`（默认）：中性填充底。**嵌在卡片内部时用这种** ——
///     填充色比卡片底色深一档，天然给出层次；
///   - `.outlined`：透明底 + 描边。**铺在大面积留白上用这种** ——
///     填充底落在纯白/纯黑上会糊出一块脏灰，描边则干净；
///   - 另有一个独立开关 `glassOnIOS26`（见下），与上面两种不冲突。
struct SecondaryButton: View {

    /// 次要按钮的两种外观。
    enum Variant {
        /// 中性填充底，适合卡片内部。
        case filled
        /// 透明底 + 描边，适合大面积留白（欢迎页）。
        case outlined
    }

    let title: String
    var systemImage: String?
    var variant: Variant = .filled
    var isEnabled: Bool = true
    /// 按钮高度。默认取令牌值；嵌在卡片里时传更小的值。
    var height: CGFloat = Tokens.Size.primaryButton

    /// 与一颗 `PrimaryButton` **同排**摆放时打开（设置页状态卡就是这种）。
    ///
    /// iOS 26 上改用系统原生玻璃次要按钮（`.buttonStyle(.glass)`），和主按钮的
    /// `.glassProminent` 构成「中性玻璃 / 强调玻璃」两级 —— 那正是苹果自己在
    /// 地图卡里用的层级语言。改之前这边走的是平铺浅灰填充 + 主题色文字，
    /// 而且**没有按压动效**，跟旁边那颗会放大发光的玻璃主按钮摆在一起，
    /// 像两套控件拼的（2026-10-15 用户原话「为啥两个按钮不一样」）。
    ///
    /// 默认 **false**：只给「与主按钮同排」的落点打开。其余各自平铺的次要按钮
    /// （诊断页、代理设置页、欢迎页）保持原样，不跟着一起变 —— 免得改一处
    /// 顺手改了十处。
    var glassOnIOS26: Bool = false

    let action: () -> Void

    @Environment(\.themeAccent) private var accent

    /// 圆角形状。填充与描边必须同形，否则描边会浮在填充外面一条缝。
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *), glassOnIOS26 {
            // 玻璃合成管线会重映射语义色，所以这里不手写
            // background / foregroundStyle —— 全交给系统，与 PrimaryButton
            // 的 `.glassProminent` 分支同一套写法。
            Button(action: action) {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.app(14, weight: .semibold))
                    }
                    Text(title)
                        .font(.app(16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
            }
            .buttonStyle(.glass)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
        } else {
            filledBody
        }
    }

    private var filledBody: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.app(14, weight: .semibold))
                }
                Text(title)
                    .font(.app(16, weight: .semibold))
            }
            .foregroundStyle(accent)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(background)
            .overlay(border)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    @ViewBuilder
    private var background: some View {
        switch variant {
        case .filled:
            shape.fill(Color.primary.opacity(Tokens.Glass.neutralCapsule))
        case .outlined:
            Color.clear
        }
    }

    /// 描边取 `Color.primary` 的透明度 —— 它是动态色，浅色下是黑描边、
    /// 深色下自动翻成白描边，不需要为深色写任何分支。
    @ViewBuilder
    private var border: some View {
        if variant == .outlined {
            shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        }
    }
}

/// 上一代实现同款按压手感（2026-10-14 二进制反汇编逐字节复刻）。
///
/// 上一代实现的 `GlassPressButtonStyle.makeBody`：
///   `label.scaleEffect(isPressed ? scale : 1, anchor: .center)`
///   `.animation(.spring(response: 0.26, dampingFraction: 0.6, blendDuration: 0), value: isPressed)`
/// —— 按下**放大**（幅度由调用方按按钮宽度传，宽按钮要收小一点），
/// 欠阻尼弹簧过冲回弹 = 用户说的「拉扯」。
///
/// 2026-10-14 曾把方向做成设置项（放大 / 缩小两档）；**2026-10-15 用户拍板
/// 收敛成固定放大回弹**，入口与另一档一起删掉，参数回到常量。
///
/// **「点亮发光」已删（2026-10-16 用户拍板）**：1.4.x 时代的提亮 + 强调色
/// 光晕圈曾于 2026-10-14 补回，后又做了三档设置；实测主按钮在 iOS 26 上
/// 走系统原生玻璃吃不到它、能吃到的只有小控件，观感割裂，整套删掉 ——
/// 现在按下只有**放大回弹**，不再发光。
/// ⚠️ 只用**渲染类**修饰符 —— 不碰 hit-test。历史那族「玻璃吃触摸」的雷
/// 都出自手势与把玻璃挂进 label，与这里无关。
///
/// **ButtonStyle 是无手势机制**：不碰 hit-test、不抢 TextField/子按钮的
/// 点击 —— 这正是上一代搜索框能输入、清除钮能点的原因（它的
/// `GlassPressModifier` 就是给子树挂这个 style）。
struct GlassPressStyle: ButtonStyle {

    /// 按下时的缩放。>1 = 放大、<1 = 缩小（由调用方按设置传）。
    var pressedScale: CGFloat = 1.05

    /// 回弹曲线。
    var animation: Animation = .spring(response: 0.26, dampingFraction: 0.6, blendDuration: 0)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(animation, value: configuration.isPressed)
    }
}

// MARK: - 全局按压反馈

extension View {

    /// 挂上「放大回弹」这套按压手感（光晕已删，2026-10-16 用户拍板维持原生）。
    ///
    /// 方向固定为放大（2026-10-15 用户拍板，设置项已删），幅度按按钮宽度传：
    /// 整宽按钮传 1.03、圆形浮钮走默认 1.05、底部大卡整宽那行传 1.06。
    ///
    /// **为什么必须是 View 扩展而不是在 ButtonStyle 里写死**：
    /// `ButtonStyle.makeBody` 不是主线程隔离的，读不了 `@MainActor` 的
    /// `DisplayPreferences`（曲线常量在那儿）。包一层 `ViewModifier`，
    /// 主线程身份与调用方自定义的幅度就都有了。
    ///
    /// - Parameter growScale: 「放大回弹」的缩放（宽按钮要收小一点，5% 位移太夸张）。
    func appPressFeedback(growScale: CGFloat = 1.05) -> some View {
        modifier(PressFeedbackModifier(growScale: growScale))
    }
}

/// 见 `View.appPressFeedback`。
private struct PressFeedbackModifier: ViewModifier {

    let growScale: CGFloat

    func body(content: Content) -> some View {
        content.buttonStyle(GlassPressStyle(
            pressedScale: growScale,
            animation: DisplayPreferences.pressFeedbackAnimation
        ))
    }
}

/// 圆形浮动按钮（地图页的顶部设置、右侧图层与实时位置都用它）。
///
/// **结构**：玻璃（`GlassContainer`）+ contentShape + 按压反馈（ButtonStyle）。
///
/// ⚠️ 历史教训（2026-10-14 真机实锤）：
/// ① 玻璃本体的任何「hidden()/clear+overlay」写法都会杀死 Button 的 hit-test；
/// ② 1.5.1 曾把 interactive 玻璃放进 label，真机上三颗圆钮点击穿透到地图
///    （1.5.0 用 `.buttonStyle(.glass)` 可点）—— 同族雷。
///
/// **2026-10-14 二次拍板：按上一代实现同构改回原生玻璃。**
/// 读上一代源码实锤：它主界面的圆钮/搜索框/大卡在 iOS 26 上就是
/// `glassEffect(Glass.regular.interactive())`，且真机可点。用户要的
/// 「按下放大 / 发光 / 拖拽」全部来自 `.interactive()`，自绘做不出来。
/// 所以 `GlassContainer` 的 iOS 26 分支把玻璃挂回内容层，并照抄上一代实现的
/// 三条命中规矩：`contentShape(shape)` 定形、装饰描边不进触摸层、
/// 嵌套档不叠玻璃。**可点性必须真机复验**（模拟器验不了触摸）。
///
/// 按压反馈仍只走 ButtonStyle（无手势机制）—— 这一条没变。
struct CircleIconButton: View {

    let systemImage: String
    var diameter: CGFloat = Tokens.Size.floatingButton
    let action: () -> Void

    @Environment(\.themeAccent) private var accent
    @StateObject private var themeStore = ThemeStore.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                // 2026-10-13 用户反馈 medium 偏细，统一升到 semibold。
                .font(.app(16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                // 自绘玻璃垫底（磨砂 + 滑杆染色 + 亮边，上一代实现同款，
                // 永远垫 background 不参与触摸）—— 正圆 = 方框 + 圆角=半径。
                // 染色：滑杆直映浓度（0=纯磨砂），基色跟主题 ——
                // 彩色渐变主题 = 主题首色，黑白极简 / 经典蓝白 = nil（不染色）。
                .glassContainer(cornerRadius: diameter / 2,
                                prominent: true,
                                adjustableTint: themeStore.glassTintBase)
        }
        // 按压反馈走全局设置（放大/缩小），并叠一层强调色光晕。
        // 无手势 —— 只挂 ButtonStyle，不会重演「玻璃吃触摸」。
        .appPressFeedback()
    }
}
