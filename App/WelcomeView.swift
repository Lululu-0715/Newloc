import SwiftUI

/// 欢迎页：三屏介绍核心能力。
///
/// **版式走「编辑感」那一路**（杂志 / 官网），而不是「图标 + 标题 + 说明」的
/// 功能说明书 —— 后者天生撑不起质感：具象图标、居中的文字块、圆点页码，
/// 这三样凑在一起就是「模板感」。这里换成四件东西：
///
///   1. 顶部**品牌字标**（宽字距）+ 右上「跳过」；
///   2. 自绘的**抽象几何**主视觉（用 SF Symbol 会立刻破功）；
///   3. **序号 + 细线 + 手工断行的大标题**；
///   4. **线性进度条**，替代圆点。
///
/// 三屏的顺序也是有讲究的：先讲「能做什么」，再讲「为什么不用折腾」，
/// 最后讲**「怎么知道成了」** —— 最后这条是上一代产品最大的痛点
/// （用户反复报告「一直正在检验 / 提示权限未开」），放最后一屏，
/// 正好接上「开始使用」。
struct WelcomeView: View {

    /// 完成或跳过后回调（由 `NewlocApp` 写入 `hasCompletedWelcome`）。
    let onFinish: () -> Void

    @State private var page = 0
    @Environment(\.themeAccent) private var accent

    /// 外观切换钮直接改这个 store。它已经挂在 `NewlocApp` 的
    /// `.preferredColorScheme` 上，所以点下去**整个窗口立刻反转** ——
    /// 这里不需要自己重绘任何东西，也不新增任何状态。
    @StateObject private var appearanceStore = AppearanceStore.shared

    // MARK: - 内容

    private struct Slide {
        let glyph: WelcomeGlyph
        /// 序号。纯装饰，不参与本地化。
        let index: String
        /// 标题。**换行是手工断的**，不是自动换行 ——
        /// 自动换行会出现一行长一行短、或者二字孤行，编辑感全靠断行位置撑着。
        let title: String
        let detail: String
    }

    private var slides: [Slide] {
        [
            Slide(glyph: .crosshair,
                  index: "01",
                  title: AppLocalization.string("不用电脑，\n不用数据线"),
                  detail: AppLocalization.string("搜索地点或直接输入经纬度，在地图上点一下就能切换。")),
            secondSlide,
            Slide(glyph: .check,
                  index: "03",
                  title: AppLocalization.string("不用猜\n成没成"),
                  detail: AppLocalization.string("端到端探测每一次改写是否真正命中，切回前台自动复验。")),
        ]
    }

    /// 第二屏按版本分文案：全能版两种模式都讲，普通版才说「不用装第三方」
    ///（2026-10-12 用户要求：全能版的欢迎页不该出现与全能版矛盾的文案）。
    private var secondSlide: Slide {
        #if THIRD_PARTY_MODE
        return Slide(glyph: .nested,
                     index: "02",
                     title: AppLocalization.string("两种模式\n随便换"),
                     detail: AppLocalization.string("内置代理开箱即用；小火箭、Surge 等客户端装上模块即可，蜂窝网络也能用。"))
        #else
        return Slide(glyph: .nested,
                     index: "02",
                     title: AppLocalization.string("不用装第三方\n客户端"),
                     detail: AppLocalization.string("代理与证书都在应用内完成，不用来回切客户端，也不用装描述文件。"))
        #endif
    }

    private var isLastPage: Bool { page == slides.count - 1 }

    // MARK: - 骨架

    var body: some View {
        ZStack {
            ThemedBackground()

            VStack(spacing: 0) {
                header

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        slidePage(slide)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack {
            // `verbatim`：这是品牌字标，不是要翻译的文案。
            Text(verbatim: "NEWLOC")
                .font(.app(11, weight: .medium))
                .tracking(2.8)
                .foregroundStyle(Color.ncTextTertiary)

            Spacer()

            Button("跳过") { onFinish() }
                .font(.app(14))
                .foregroundStyle(Color.ncTextSecondary)
                .buttonStyle(.plain)
                // 最后一屏不再显示「跳过」—— 此时它和主按钮是同一个动作，
                // 两个入口做同一件事会让人犹豫点哪个。
                .opacity(isLastPage ? 0 : 1)
                .disabled(isLastPage)
        }
        .padding(.horizontal, Tokens.Spacing.welcome)
        .padding(.top, 16)
        .frame(height: 44)
    }

    // MARK: - 单屏

    private func slidePage(_ slide: Slide) -> some View {
        VStack(spacing: 0) {
            SlideGlyph(kind: slide.glyph, tint: accent)
                .padding(.top, 36)

            // 主视觉贴着上方，文案贴着下方，中间让给留白 ——
            // 把内容垂直居中会显得「居中得很随意」，上下分挂才有版式感。
            Spacer(minLength: 0)

            caption(slide)
        }
    }

    private func caption(_ slide: Slide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: slide.index)
                    .font(.app(13, weight: .medium))
                    .foregroundStyle(Color.ncTextTertiary)

                // 发丝线：用 `Color.primary` 的透明度而不是固定灰色，
                // 浅色深色都自动成立。
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
            }
            .padding(.bottom, 14)

            Text(verbatim: slide.title)
                .font(.app(30, weight: .medium))
                .tracking(-0.5)
                .lineSpacing(3)
                .foregroundStyle(Color.ncText)
                // 小屏（iPhone SE 320pt）右端会顶格，缩一点点比截断好。
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: slide.detail)
                .font(.app(15))
                .foregroundStyle(Color.ncTextSecondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.welcome)
        .padding(.bottom, 30)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 18) {
            progressRow

            if isLastPage {
                PrimaryButton(title: AppLocalization.string("开始使用"), action: onFinish)
            } else {
                SecondaryButton(title: AppLocalization.string("继续"),
                                variant: .outlined) {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.welcome)
        .padding(.bottom, 28)
    }

    /// 进度条 + 外观切换钮。
    ///
    /// **钮为什么在这一行**：右上角已经被「跳过」占住了，两个控件并排会挤，
    /// 而且「跳过」是高频动作（想快进的人一点就走），不该被一个低频的
    /// 外观钮推到旁边。这一行本来就是「左对齐 + 右侧一片空」，是天然空位。
    private var progressRow: some View {
        HStack(spacing: 12) {
            progressBar

            Spacer(minLength: 0)

            appearanceToggle
        }
    }

    /// 外观切换钮：点击在 `浅色 ⇄ 深色` 之间切换。
    ///
    /// 选了之后会写进 `appearanceMode`，设置页「外观」那一行读的是同一个值 ——
    /// 也就是说这里只是把设置页已有的能力**提前暴露**，两边永远一致。
    private var appearanceToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.28)) { appearanceStore.toggle() }
        } label: {
            ContrastMark(tint: accent)
                .frame(width: 30, height: 30)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.string("切换外观"))
        // 读屏报的是**实际显示**的明暗，而不是「跟随系统」这种模式名 ——
        // 用户关心的是"现在到底是黑的还是白的"。
        .accessibilityValue(appearanceStore.effectiveScheme == .dark
                            ? AppLocalization.string("深色")
                            : AppLocalization.string("浅色"))
    }

    /// 线性进度条：靠左排、每一段等宽，当前段用强调色。
    ///
    /// **为什么不是圆点**：圆点是「轮播图」的语言，线性分段是「编辑版面」的语言。
    /// 而且分段能一眼数出还剩几屏，圆点在小尺寸下数不清。
    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(slides.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? accent : Color.primary.opacity(0.13))
                    .frame(width: 34, height: 3)
                    .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
    }
}

// MARK: - 外观切换钮的图标

/// 对比度圆：左半实心、右半空心。
///
/// 它整只用 `Color.primary` 一类的动态色画，所以**浅色下是左黑右白、
/// 深色下自动翻成左白右黑** —— 不用写任何外观判断，一眼也能看出当前在哪一档。
private struct ContrastMark: View {

    let tint: Color

    private let diameter: CGFloat = 13

    var body: some View {
        ZStack {
            // 左半圆：整圆填充后用「左半边矩形」裁掉右半。
            // 比用 `trim` / `addArc` 拼半圆可靠得多 —— 那两个的角度方向
            // 在 y 轴向下的坐标系里很容易切出右半圆。
            Circle()
                .fill(tint)
                .frame(width: diameter, height: diameter)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: diameter / 2, height: diameter)
                }

            Circle()
                .strokeBorder(tint, lineWidth: 1.4)
                .frame(width: diameter, height: diameter)
        }
    }
}

// MARK: - 主视觉

/// 主视觉的三种几何母题。
///
/// 三屏共用同一个「外环 + 缺口弧」的骨架，只换中心符号 ——
/// 这样翻页时看到的是「同一套语言里的三种表达」，而不是三个互不相干的小图标。
///
/// 定在文件级而不是嵌进 `WelcomeView`：`private` 的嵌套类型只对所属类型可见，
/// 同文件里的 `SlideGlyph` 读不到它。
private enum WelcomeGlyph {
    /// 准星 + 实心点：锁定一个坐标。
    case crosshair
    /// 双层菱形：自包含（内置代理）。
    case nested
    /// 对勾：有结论，不靠猜。
    case check
}

/// 自绘几何主视觉。
///
/// 骨架固定：外环（极淡）+ 中环的缺口弧（稍亮）+ 中心符号。
/// 三层都是**同一强调色加不同透明度** —— 这样换成任何主题色都自动成立，
/// 也不需要为深色模式单独调色（黑白主题的强调色本身会反转）。
private struct SlideGlyph: View {

    let kind: WelcomeGlyph
    let tint: Color

    private let size: CGFloat = 180
    /// 中环直径与外环的比例。0.733 是照着 120pt 画布上 r=44 / r=59 定的。
    private let ringRatio: CGFloat = 0.733

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.09), lineWidth: 1)
                .frame(width: size, height: size)

            Circle()
                .fill(tint.opacity(0.03))
                .frame(width: size * ringRatio, height: size * ringRatio)

            // 缺口弧：留 28% 的缺口，起点转到 12 点方向。
            // 完整圆环会显得像个加载指示器，开个口才像仪表盘。
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(tint.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: size * ringRatio, height: size * ringRatio)
                .rotationEffect(.degrees(-90))

            symbol
        }
        .frame(width: size, height: size)
        // 这是纯装饰，不具备语义 —— 对 VoiceOver 隐藏，让读屏直接读标题。
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var symbol: some View {
        switch kind {
        case .crosshair:
            ZStack {
                // 四条准星短线：绕中心各转 90°。外侧留白比内侧多，
                // 是为了不贴到中环上，看着才透气。
                ForEach(0..<4, id: \.self) { quadrant in
                    Capsule()
                        .fill(tint.opacity(0.5))
                        .frame(width: 1.5, height: 15)
                        .offset(y: -34.5)
                        .rotationEffect(.degrees(Double(quadrant) * 90))
                }

                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }

        case .nested:
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.opacity(0.85), lineWidth: 1.6)
                    .frame(width: 39, height: 39)
                    .rotationEffect(.degrees(45))

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(tint.opacity(0.4), lineWidth: 1.3)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(45))
            }

        case .check:
            CheckShape()
                .stroke(tint.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .frame(width: 39, height: 29)
        }
    }
}

/// 对勾。三条点连成 V 字形，长臂比短臂长得多（大约 2:1），
/// 这个比例是照着手写对勾的手感定的，等腰 V 会显得很「图标」。
private struct CheckShape: Shape {

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.62))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
