import SwiftUI

/// 设置页。
///
/// 版式沿用上一代：分组卡片 + 实心圆图标 + 右侧当前取值 + 只读行不带箭头。
///
/// 相对上一代有三处调整（详见 `docs/02-UI设计-黑白配色.md`）：
///   1. 「运行模式」原来独占一个分组（只有一行），并入「连接与代理」；
///   2. **新增置顶「运行状态」卡** —— 上一代的生效结论只在地图页底部能看到，
///      一进设置就没了，用户要来回切屏确认；
///   3. 「主题」改名「外观」（明暗），「配色主题」是另一件事，两行分开。
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var appearanceStore = AppearanceStore.shared
    @StateObject private var displayPreferences = DisplayPreferences.shared

    /// 状态卡与两个校验开关都直连真实实现 —— 不再有占位数据。
    @StateObject private var verifier = SpoofEffectVerifier.shared
    @StateObject private var verification = VerificationSettings.shared

    /// 连接层的两条实测证据，与 `ProxySetupView` 共享同一份 ——
    /// 两个页面各测各的，切来切去时会在毫秒级里反复起停临时服务。
    @StateObject private var proxy = ProxyController.shared
    @StateObject private var diagnostics = ConnectionDiagnostics.shared

    #if THIRD_PARTY_MODE
    @StateObject private var modeStore = ModeStore.shared
    @StateObject private var thirdParty = ThirdPartyController.shared
    #endif

    var body: some View {
        NavigationView {
            ZStack {
                ThemedBackground()

                // `ScrollViewReader` 只是给烟测留一个滚动锚点（模拟器没有
                // 滚动手段，外观分组在一屏之外截不到）。它对 Release 是透明的。
                ScrollViewReader { proxy in
                    ScrollView {
                        // 2026-10-14 统一：组间距 24、顶部 16、左右 20
                        // （设置一级 + 全部二级页同一套，别再单页分叉）。
                        VStack(spacing: 24) {
                            statusCard
                            // 2026-10-13 用户要求合并：全能版「运行模式」并入连接组；
                            // 普通版没有模式概念，保持「连接与代理」。
                            #if THIRD_PARTY_MODE
                            modeAndConnectionGroup
                            #else
                            connectionGroup
                            #endif
                            locatingGroup
                            appearanceGroup
                            aboutGroup
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 40)
                    }
                    #if UI_TEST_HOOKS
                    .onAppear { scrollToUITestAnchor(proxy, anchorID: "appearance") }
                    #endif
                }

                #if UI_TEST_HOOKS
                uiTestLinks
                #endif
            }
            .navigationTitle(AppLocalization.string("设置"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(AppLocalization.string("完成")) { dismiss() }
                        .font(.app(16, weight: .medium))
                }
            }
        }
        .navigationViewStyle(.stack)
        // 进设置页就刷新一次连接状态 —— 用户多半是「感觉不对」才来这儿，
        // 摆一份陈旧结论在这里没有意义。
        .task { await diagnostics.refresh() }
    }

    #if UI_TEST_HOOKS
    // MARK: - 界面测试注入口

    /// 二级页直达钩子（烟测用）。模拟器没有触控手段，`NavigationLink`
    /// 点不动 —— 设置页二级页面的截图全靠它，和 `MapHomeView` 的
    /// `-uiTest.initialSheet` 是同一套路子。
    ///
    /// 用法：`... -uiTest.initialSheet settings -uiTest.settingsPage transparency`
    /// 取值：`appearance`（外观汇总）/ `tint`（玻璃染色）/ `transparency`（玻璃透明度）。
    ///
    /// 只在 Debug 下编入（`UI_TEST_HOOKS`，见 `project.yml`），Release 包里没有这段。
    @State private var uiTestPage = UserDefaults.standard.string(forKey: "uiTest.settingsPage")

    @ViewBuilder
    private var uiTestLinks: some View {
        NavigationLink(isActive: uiTestBinding("appearance")) {
            AppearancePickerView()
        } label: { EmptyView() }

        NavigationLink(isActive: uiTestBinding("tint")) {
            GlassOpacityView()
        } label: { EmptyView() }

        NavigationLink(isActive: uiTestBinding("transparency")) {
            GlassTransparencyView()
        } label: { EmptyView() }
    }

    private func uiTestBinding(_ page: String) -> Binding<Bool> {
        Binding(get: { uiTestPage == page },
                set: { if !$0 { uiTestPage = nil } })
    }

    /// 启动即滚到 `-uiTest.scrollTo` 指定的锚点（烟测用，模拟器滚不动页面）。
    private func scrollToUITestAnchor(_ proxy: ScrollViewProxy, anchorID: String) {
        guard UserDefaults.standard.string(forKey: "uiTest.scrollTo") == anchorID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            proxy.scrollTo(anchorID, anchor: .bottom)
        }
    }
    #endif

    // MARK: - 置顶状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Circle()
                    .fill(verifier.state.tint.color)
                    .frame(width: 9, height: 9)

                Text(stateTitle)
                    .font(.app(17, weight: .semibold))
                    .foregroundStyle(Color.ncText)

                Spacer(minLength: 0)

                if let verifiedAt = verifier.verifiedAt {
                    Text(timeText(verifiedAt))
                        .font(.app(13))
                        .foregroundStyle(Color.ncTextSecondary)
                }
            }

            Text(statusDetail)
                .font(.app(12))
                .foregroundStyle(Color.ncTextSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack(spacing: 8) {
                // 2026-10-15 用户拍板：这两颗要像一套。右边是玻璃主按钮
                // （iOS 26 上 `.glassProminent`），这颗跟着上系统原生玻璃次要按钮，
                // 一起构成「中性玻璃 / 强调玻璃」两级；此前这边是平铺浅灰底 +
                // 主题色文字、且**没有按压动效**，摆一起像两套控件拼的。
                SecondaryButton(title: AppLocalization.string("重新验证"),
                                isEnabled: isActive,
                                height: 36,
                                glassOnIOS26: true) {
                    verifier.reverify()
                }
                PrimaryButton(title: AppLocalization.string("停止"),
                              isEnabled: isActive,
                              height: 36) {
                    verifier.reset()
                }
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

    private var stateTitle: String {
        switch verifier.state {
        case .effective: return AppLocalization.string("虚拟定位已生效")
        case .verifying: return AppLocalization.string("正在校验…")
        case .idle: return AppLocalization.string("虚拟定位未开始")
        case .ineffective(let reason): return reason.text
        }
    }

    private var statusDetail: String {
        switch verifier.state {
        case .effective:
            return AppLocalization.string("改写已命中，系统当前的位置就是选点位置。")
        case .verifying:
            return AppLocalization.string("正在端到端探测，请保持应用在前台。")
        case .idle:
            return AppLocalization.string("回到主界面设置目标坐标并开始定位。")
        case .ineffective(let reason):
            return reason.advice
        }
    }

    /// 没有目标点时，「重新验证 / 停止」都是无意义的。
    private var isActive: Bool { verifier.state != .idle }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 模式与连接（全能版）

    #if THIRD_PARTY_MODE
    /// 模式与连接（2026-10-13 用户要求合并）。
    ///
    /// 原来「运行模式」独占一个只有一行的分组，「连接与代理」里又藏着
    /// 同一套代理软件相关内容 —— 两处入口说的是一件事。合并后：
    /// 第一行选模式，下面跟着**当前模式**的连接状态与设置入口。
    private var modeAndConnectionGroup: some View {
        SettingsGroup(title: AppLocalization.string("模式与连接"),
                      // 上一代实现同款：第三方模式下在分组底部放一段行为说明。
                      footnote: modeStore.mode == .thirdParty
                          ? AppLocalization.string("第三方模式由你自己的代理客户端执行改写，可覆盖蜂窝网络，无需安装本应用证书。")
                          : nil) {
            NavigationLink {
                RunModeSettingsView()
            } label: {
                SettingsRow(systemImage: "arrow.triangle.swap",
                            title: AppLocalization.string("运行模式"),
                            value: modeStore.mode.displayName,
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            if modeStore.mode == .thirdParty {
                thirdPartyConnectionRows
            } else {
                builtInConnectionRows
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    /// 第三方模式下的连接行：模块连通 + 设置入口（代理服务/证书那几行
    /// 与本模式无关，显示出来只会误导）。
    private var thirdPartyConnectionRows: some View {
        Group {
            SettingsRow(systemImage: "antenna.radiowaves.left.and.right",
                        title: AppLocalization.string("模块连通"),
                        value: thirdParty.statusText,
                        valueColor: thirdParty.state == .moduleIdle || thirdParty.state == .active
                            ? .green
                            : (thirdParty.state == .unreachable ? StatusTint.ineffective.color : Color.ncTextSecondary))

            SettingsRowDivider()

            NavigationLink {
                ThirdPartySetupView()
            } label: {
                SettingsRow(systemImage: "wrench.and.screwdriver",
                            title: AppLocalization.string("连接设置"),
                            value: AppLocalization.string("模块与客户端"),
                            showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }
    #endif

    // MARK: - 连接与代理（普通版）

    #if !THIRD_PARTY_MODE
    /// 普通版的「连接与代理」。每一行都由实测驱动，拿不到证据时显示
    /// 「未检测」而不是编一个好看的答案。
    private var connectionGroup: some View {
        SettingsGroup(title: AppLocalization.string("连接与代理")) {
            builtInConnectionRows
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }
    #endif

    /// 内置代理模式的「连接与代理」四行 + 入口（两版共用）。
    private var builtInConnectionRows: some View {
        Group {
            SettingsRow(systemImage: "shield.lefthalf.filled",
                        title: AppLocalization.string("代理服务"),
                        value: proxyText,
                        valueColor: proxyColor)

            SettingsRowDivider()

            SettingsRow(systemImage: "checkmark.shield",
                        title: AppLocalization.string("根证书"),
                        value: diagnostics.trust.text,
                        valueColor: trustColor)

            SettingsRowDivider()

            SettingsRow(systemImage: "point.3.connected.trianglepath.dotted",
                        title: AppLocalization.string("Wi-Fi 代理"),
                        value: linkText,
                        valueColor: linkColor)

            SettingsRowDivider()

            NavigationLink {
                ProxySetupView()
            } label: {
                SettingsRow(systemImage: "wrench.and.screwdriver",
                            title: AppLocalization.string("连接设置"),
                            value: AppLocalization.string("证书与代理"),
                            showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var proxyText: String {
        switch proxy.status {
        case .stopped: return AppLocalization.string("已停止")
        case .starting: return AppLocalization.string("启动中…")
        case .running: return AppLocalization.string("运行中 · %@", String(ProxyController.port))
        case .failed(let failure): return failure.title
        }
    }

    private var proxyColor: Color {
        switch proxy.status {
        case .running: return .green
        case .starting: return StatusTint.verifying.color
        case .failed: return StatusTint.ineffective.color
        case .stopped: return Color.ncTextSecondary
        }
    }

    private var trustColor: Color {
        switch diagnostics.trust {
        case .trusted: return .green
        case .untrusted: return StatusTint.ineffective.color
        case .unavailable: return Color.ncTextSecondary
        }
    }

    private var linkText: String {
        switch diagnostics.link {
        case .alive: return AppLocalization.string("已连通")
        case .tlsRejected: return AppLocalization.string("证书未受信任")
        case .unknown: return AppLocalization.string("未检测")
        }
    }

    private var linkColor: Color {
        switch diagnostics.link {
        case .alive: return .green
        case .tlsRejected: return StatusTint.ineffective.color
        case .unknown: return Color.ncTextSecondary
        }
    }

    // MARK: - 定位与持久化

    private var locatingGroup: some View {
        SettingsGroup(title: AppLocalization.string("定位与校验")) {
            SettingsRow(systemImage: "scope",
                        title: AppLocalization.string("定位精度"),
                        value: AppLocalization.string("最高"))
            SettingsRowDivider()
            // 开关行为直接写进说明行（随状态切换），不再塞条件说明卡 ——
            // 2026-10-13 用户反馈设置页拥挤，能收进行内的说明都收进去。
            SettingsToggleRow(systemImage: "checkmark.circle",
                              title: AppLocalization.string("自动校验"),
                              subtitle: AppLocalization.string(verification.autoVerifyEnabled
                                  ? "开启后持续探测，直到给出结论"
                                  : "已关闭：开始定位时仍会检查一次"),
                              isOn: $verification.autoVerifyEnabled)
            SettingsRowDivider()
            SettingsToggleRow(systemImage: "arrow.clockwise",
                              title: AppLocalization.string("回前台自动重校验"),
                              subtitle: AppLocalization.string("从后台回到前台时接着校验一轮"),
                              isOn: $verification.reverifyOnForeground)
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    // MARK: - 外观及个性化

    private var appearanceGroup: some View {
        SettingsGroup(title: AppLocalization.string("外观及个性化")) {
            NavigationLink {
                AppearancePickerView()
            } label: {
                SettingsRow(systemImage: "circle.lefthalf.filled",
                            title: AppLocalization.string("外观"),
                            value: appearanceStore.mode.displayName,
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            NavigationLink {
                LanguagePickerView()
            } label: {
                SettingsRow(systemImage: "globe",
                            title: AppLocalization.string("语言"),
                            value: displayPreferences.language.displayName,
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            NavigationLink {
                FontSizePickerView()
            } label: {
                SettingsRow(systemImage: "textformat.size",
                            title: AppLocalization.string("字体大小"),
                            value: displayPreferences.fontSize.displayName,
                            showsChevron: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Tokens.Spacing.page)
        // 烟测滚动锚点，见 `scrollToUITestAnchor`。对 Release 无影响。
        .id("appearance")
    }

    // MARK: - 关于

    private var aboutGroup: some View {
        SettingsGroup(title: AppLocalization.string("关于")) {
            NavigationLink {
                ManualView()
            } label: {
                SettingsRow(systemImage: "book",
                            title: AppLocalization.string("使用手册"),
                            subtitle: AppLocalization.string("从装包到关闭，新手照着做就能用"),
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            NavigationLink {
                DiagnosticsView()
            } label: {
                SettingsRow(systemImage: "doc.text.magnifyingglass",
                            title: AppLocalization.string("诊断日志"),
                            value: AppLocalization.string("最近 200 条"),
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            SettingsRow(systemImage: "info.circle",
                        title: AppLocalization.string("应用版本"),
                        value: appVersion)
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - 外观汇总

/// 外观汇总页：明暗、配色主题、玻璃染色、玻璃透明度都归到这里。
///
/// **2026-10-15 用户拍板**：「把配色主题、玻璃染色和玻璃透明度都放到外观里面
/// 归类」。此前这四项平铺在一级「外观及个性化」分组里，一级菜单被撑成七行，
/// 而「外观」（明暗）与「配色主题」（品牌色）说的根本不是一件事，很容易点错。
/// 现在一级只剩「外观 / 语言 / 字体大小」三行，四项里除明暗在页内直选外，
/// 其余都从这一页进。
struct AppearancePickerView: View {

    @StateObject private var store = AppearanceStore.shared
    @StateObject private var themeStore = ThemeStore.shared
    @StateObject private var prefs = DisplayPreferences.shared
    // accent 环境属性已删（2026-10-16 审查）：明暗改分段控件后无人再读，
    // 留着是死声明。

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 24) {
                    modeGroup
                    colorAndGlassGroup
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("外观"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 明暗

    /// 一行「主题」+ 右侧三段分段控件（2026-10-16 用户拿参考截图拍板，
    /// 替换原三行打勾列表）。
    private var modeGroup: some View {
        SettingsGroup(title: AppLocalization.string("明暗")) {
            HStack(spacing: Tokens.Spacing.rowIcon) {
                SettingsIconBadge(systemImage: "circle.lefthalf.filled")

                Text(AppLocalization.string("主题"))
                    .font(.app(16))
                    .foregroundStyle(Color.ncText)

                Spacer(minLength: 8)

                Picker(AppLocalization.string("主题"), selection: $store.mode) {
                    ForEach(AppearanceStore.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // 不定宽：分段控件默认横给铺满，分段按钮自动吃到剩余宽度
                //（2026-10-16 用户反馈段钮太小；小屏自适应，不会溢出）。
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Tokens.Spacing.row)
            .padding(.vertical, 12)
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    // MARK: - 配色与玻璃

    private var colorAndGlassGroup: some View {
        SettingsGroup(title: AppLocalization.string("配色与玻璃")) {
            NavigationLink {
                ThemePickerView()
            } label: {
                SettingsRow(systemImage: "paintpalette",
                            title: AppLocalization.string("配色主题"),
                            value: themeStore.theme.displayName,
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            NavigationLink {
                GlassOpacityView()
            } label: {
                SettingsRow(systemImage: "square.on.square.intersection.dashed",
                            title: AppLocalization.string("玻璃染色"),
                            value: "\(DisplayPreferences.glassOpacityPercent(prefs.glassOpacity))%",
                            showsChevron: true)
            }
            .buttonStyle(.plain)

            SettingsRowDivider()

            NavigationLink {
                GlassTransparencyView()
            } label: {
                SettingsRow(systemImage: "circle.dashed",
                            title: AppLocalization.string("玻璃透明度"),
                            value: "\(DisplayPreferences.glassTransparencyPercent(prefs.glassTransparency))%",
                            showsChevron: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }
}

// MARK: - 语言选择

/// 应用内语言覆盖：跟随系统 / 简体中文 / 繁體中文 / English。
struct LanguagePickerView: View {

    @StateObject private var store = DisplayPreferences.shared
    @Environment(\.themeAccent) private var accent

    var body: some View {
        optionList(title: AppLocalization.string("语言")) {
            ForEach(DisplayPreferences.Language.allCases) { language in
                optionRow(title: language.displayName,
                          isSelected: store.language == language,
                          accent: accent) {
                    store.language = language
                }
            }
        }
    }
}

// MARK: - 字体大小

/// 全局字号：四档缩放，选中行文字用该档实际字号预览。
struct FontSizePickerView: View {

    @StateObject private var store = DisplayPreferences.shared
    @Environment(\.themeAccent) private var accent

    var body: some View {
        optionList(title: AppLocalization.string("字体大小")) {
            ForEach(DisplayPreferences.FontSize.allCases) { size in
                Button {
                    store.fontSize = size
                } label: {
                    HStack(spacing: 12) {
                        // 用该档缩放后的实际大小写字，所见即所选。
                        Text(size.displayName)
                            .font(.system(size: 16 * size.scale))
                            .foregroundStyle(Color.ncText)

                        Spacer(minLength: 0)

                        if store.fontSize == size {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.row)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if size != DisplayPreferences.FontSize.allCases.last {
                    Divider().padding(.leading, Tokens.Spacing.row)
                }
            }
        }
    }
}

// MARK: - 玻璃染色

/// 玻璃**染色**滑杆：主题色往玻璃上叠多厚。实时生效（走环境观察，
/// 不需要整树重建），页内放一张迷你玻璃卡预览当前效果。
///
/// 注意与「玻璃透明度」的区别：这里调的是**颜色层**，透明度调的是
/// **玻璃本身多厚**。两个是正交的轴，2026-10-14 用户拍板拆开。
///
/// **2026-10-15 追加：无渐变主题下这根滑杆不生效。**
/// 黑白极简 / 经典蓝白这两套主题的定位是「中性底 + 一个强调色」，染色基色
/// 返回 nil，玻璃保持系统中性（用户原话：「这两个蓝白就是蓝色和白色，
/// 黑白就是黑色和白色，不需要把卡片搜索框浮标按钮的玻璃上色」）。
/// 所以选中这两套主题时滑杆置灰并写明原因 —— 留一根拉不动任何东西的控件
/// 比不给更糟（2026-10-14 那轮「滑杆不起作用」就是这么来的）。
struct GlassOpacityView: View {

    @StateObject private var store = DisplayPreferences.shared
    @StateObject private var themeStore = ThemeStore.shared
    @Environment(\.themeAccent) private var accent

    /// 当前配色主题有没有玻璃染色基色。
    /// 无渐变主题（黑白极简 / 经典蓝白）为 false —— 见 `ThemeStore.glassTintBase`。
    private var isTintAvailable: Bool { themeStore.glassTintBase != nil }

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 20) {
                    previewCard
                    sliderBlock
                    if !isTintAvailable { unavailableNotice }
                    resetButton
                }
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle(AppLocalization.string("玻璃染色"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 预览

    /// 预览卡：就是主界面底部卡片同款玻璃（尺寸缩小）。
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("预览"))
                .font(.app(17, weight: .semibold))
                .foregroundStyle(Color.ncText)

            Text(isTintAvailable
                 ? AppLocalization.string("拖动滑杆，这张卡片的染色实时变化。")
                 : AppLocalization.string("当前主题不使用玻璃染色，这张卡片保持中性玻璃。"))
                .font(.app(13))
                .foregroundStyle(Color.ncTextSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ⚠️ 必须走 `adjustableTint`（滑杆驱动）而不是固定 `tint`：
        // 传固定 tint 时 `GlassContainer` 的染色分支会直接 return 一个
        // 与滑杆无关的常量，**拖滑杆这张卡纹丝不动** —— 页面文案
        // 「拖动滑杆实时变化」就成了假话（2026-10-14 用户实测）。
        .glassContainer(cornerRadius: 20,
                        adjustableTint: themeStore.glassTintBase)
        // 与滑块同边距（2026-10-14 用户反馈预览卡贴边）。
        .padding(.horizontal, Tokens.Spacing.page)
    }

    // MARK: - 滑杆

    private var sliderBlock: some View {
        VStack(spacing: 6) {
            Slider(value: $store.glassOpacity,
                   in: DisplayPreferences.glassOpacityRange)
                // 滑杆跟主题色走（系统默认是蓝，与整页配色打架）。
                .tint(accent)
                .disabled(!isTintAvailable)

            HStack {
                // 步进按钮（2026-10-14 用户反馈两端难拉满）：
                // thumb 有宽度，视觉上永远差半格；每点一下 ±5，
                // 能精确走到 0 和 100。
                stepButton(title: AppLocalization.string("更淡"),
                           delta: -0.05,
                           disabled: !isTintAvailable
                               || store.glassOpacity <= DisplayPreferences.glassOpacityRange.lowerBound)

                Spacer(minLength: 0)

                // 取整统一走共用函数 —— 2026-10-15：一级菜单曾显示 49、这里显示 50。
                // 百分号也必须带上：一级那一行是「50%」，这里原来只有「50」，
                // 同一个状态两种呈现（2026-10-15 审查 B6）。
                Text("\(DisplayPreferences.glassOpacityPercent(store.glassOpacity))%")
                    .font(.app(13, weight: .semibold).monospaced())
                    .foregroundStyle(isTintAvailable ? Color.ncText : Color.ncTextTertiary)

                Spacer(minLength: 0)

                stepButton(title: AppLocalization.string("更浓"),
                           delta: 0.05,
                           disabled: !isTintAvailable
                               || store.glassOpacity >= DisplayPreferences.glassOpacityRange.upperBound)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
        .padding(.top, 6)
    }

    /// 无渐变主题的说明条。
    private var unavailableNotice: some View {
        Text(AppLocalization.string("配色主题「%@」只用中性底加一个强调色，不参与玻璃染色；换成彩色渐变主题后这根滑杆即可使用。",
                                    themeStore.theme.displayName))
            .font(.app(13))
            .foregroundStyle(Color.ncTextSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Tokens.Spacing.page)
    }

    // MARK: - 恢复默认

    private var resetButton: some View {
        Button {
            // 「恢复默认」的目标值是用户拍板的 30，不是新装初始默认 0
            //（2026-10-15 拍板，见 `DisplayPreferences.resetGlassOpacity`）。
            store.glassOpacity = DisplayPreferences.resetGlassOpacity
        } label: {
            Text(AppLocalization.string("恢复默认"))
                .font(.app(15, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isTintAvailable)
    }

    /// 端点步进钮：label 沿用「更淡/更浓」文案，可点、到端点置灰。
    private func stepButton(title: String, delta: Double, disabled: Bool) -> some View {
        Button {
            store.glassOpacity = min(max(store.glassOpacity + delta,
                                         DisplayPreferences.glassOpacityRange.lowerBound),
                                     DisplayPreferences.glassOpacityRange.upperBound)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: delta < 0 ? "minus.circle" : "plus.circle")
                    .font(.app(12, weight: .medium))
                Text(title)
                    .font(.app(12))
            }
            .foregroundStyle(disabled ? Color.ncTextTertiary : accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

// MARK: - 玻璃透明度

/// 玻璃**透明度**：一根滑杆，调玻璃多实。
///
/// **2026-10-15 用户拍板删掉三档档位器。** 档位与滑杆说的本来是同一件事，
/// 摆两套控件等于要用户先挑一套用；它在 iOS 26 上还掺了「原生玻璃只有固定
/// 风格档」这个实现细节，等于把内部限制露到了界面上。现在限制收进
/// `GlassContainer`，界面只留一根滑杆。
///
/// **iOS 26 上这根滑杆是怎么"连续"的**：本机 SDK 的 `Glass` 只有
/// `clear` / `regular` / `identity` 三个静态成员，**没有连续「厚度」参数**
///（头文件实读）。所以滑杆拆成两件事合成：0.33 以下用 `Glass.clear`
/// 保证"最透"真的透，0.33 以上切 `Glass.regular`，再叠一层浓度随滑杆走的
/// 中性色把中间那一段补平 —— 曲线见 `GlassContainer` 的
/// `nativeCompactionOpacity`。
///
/// **iOS 15 ~ 18** 走自绘降级：材质固定「通透」档那两档，滑杆直接调那一层的
/// 不透明度（`DisplayPreferences.materialOpacity`），全程连续、无跳变。
struct GlassTransparencyView: View {

    @StateObject private var store = DisplayPreferences.shared
    @Environment(\.themeAccent) private var accent

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 20) {
                    previewCard
                    sliderBlock
                    footnote
                    resetButton
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("玻璃透明度"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 预览卡：读的就是全局设置，拖滑杆它立刻变。
    ///
    /// ⚠️ 刻意**不传 `tint` / `adjustableTint`**：传了染色，玻璃上那层颜色会把
    /// 厚薄的差别盖住 —— 2026-10-14 用户实测「换档没反应」就是染色插了一脚。
    /// 这张卡要展示的就是玻璃本身的厚薄，所以保持中性（老系统上会退回按材质
    /// 挑系统材质那一档）。
    ///
    /// **卡片底下垫了一层「有条纹的背景」**（2026-10-14 用户拍板）：
    /// iOS 26 原生玻璃的厚薄差的是**背景模糊程度**，而页面背景是纯色渐变、
    /// 没有细节可模糊 —— 在一张纯色卡上几乎是同一个样子（实测逐像素
    /// `meanDiff` 只有 4.63，肉眼不分档）。垫上高频细节之后模糊才读得出来：
    /// 最透那端条纹清晰、最实那端糊成一片。2026-10-15 改成滑杆之后，
    /// 这张卡仍然是判断"每一格有没有真的变"的唯一依据。
    private var previewCard: some View {
        ZStack {
            previewBackdrop

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.string("预览"))
                    .font(.app(17, weight: .semibold))
                    .foregroundStyle(Color.ncText)
                Text(glassPreviewSubtitle)
                    .font(.app(13))
                    .foregroundStyle(Color.ncTextSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .glassContainer(cornerRadius: 20)
        }
        // 固定高度：垫底与卡片的尺寸都由它定，两者才能严丝合缝地叠在一起。
        .frame(height: 112)
        .padding(.horizontal, Tokens.Spacing.page)
    }

    /// 预览卡底下那层「有细节的背景」—— 一串高对比细条纹。
    ///
    /// 选条纹而不是色块：模糊程度最容易在**高频细节**上读出来
    ///（色块被模糊之后还是色块，条纹被模糊之后直接糊掉）。
    private var previewBackdrop: some View {
        VStack(spacing: 5) {
            ForEach(0..<8, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index.isMultiple(of: 2)
                          ? accent.opacity(0.55)
                          : Color.ncTextTertiary.opacity(0.45))
                    .frame(height: 7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 预览卡副标题。滑杆现在全系统都有，文案也就不再分叉。
    private var glassPreviewSubtitle: String {
        AppLocalization.string("拖动滑杆，这张卡片的玻璃实时变化。")
    }

    /// 滑杆：一根到底。往左更透、往右更实。
    private var sliderBlock: some View {
        VStack(spacing: 6) {
            Slider(value: $store.glassTransparency,
                   in: DisplayPreferences.glassTransparencyRange)
                // 与「玻璃染色」那条同款：跟主题色，不用系统蓝。
                .tint(accent)

            // 百分比：与一级菜单共用同一个取整函数（2026-10-15 的 50 / 49 就是这么来的），
            // 百分号也要与一级一致（2026-10-15 审查 B6）。
            //
            // **2026-10-15 用户拍板：删掉两端「更透 / 更实」两个步进按钮。**
            // 它们是我上一轮自己加的，用户从没要求过；而且高亮逻辑是
            // `disabled ? Color.ncTextTertiary : accent`、判的是「已经在端点」，
            // 结果绿色高亮永远落在**离滑块最远**的那一端 —— 滑杆拉到 100（最实）
            // 时亮的却是「更透」，读起来正好是反的。删掉之后这一页就只剩用户
            // 要的那一根滑杆，没有第二种说法。
            Text("\(DisplayPreferences.glassTransparencyPercent(store.glassTransparency))%")
                .font(.app(13, weight: .semibold).monospaced())
                .foregroundStyle(Color.ncText)
                // 默认居中，与原先「两个 Spacer 夹一段文字」的排布完全等价，
                // 不会造成视觉位移。
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Tokens.Spacing.page)
        .padding(.top, 6)
    }

    /// 说明段。**必须按系统分叉**（2026-10-15 审查 B1）。
    ///
    /// 原来这一句是无条件渲染的、而且写死了「本机是 iOS 26」——
    /// 可 `GlassTransparencyView` 通篇没有任何版本判断，iOS 15~18 走的是
    /// `GlassContainer.legacyGlass`：材质层不透明度**全区间连续可调**，
    /// 根本不存在「33% 处切换一次」这回事。老系统用户读到的是对当前设备
    /// 完全错误的一句说明，还会照着去找那个不存在的跳变。
    ///
    /// 顺带把版本号从文案里去掉了（`docs/01-方案设计.md` 的约定：UI 不写版本号，
    /// 要分叉就走能力判断）—— 字符串里带「iOS 26」到了 iOS 27 又会变成新的谎话。
    private var footnote: some View {
        Text(footnoteText)
            .font(.app(13))
            .foregroundStyle(Color.ncTextSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Spacing.page)
    }

    private var footnoteText: String {
        if #available(iOS 26.0, *) {
            return AppLocalization.string(
                "本机系统的原生玻璃只有「通透 / 标准」两种材质，滑杆在 33% 处会切换一次；其余区间由一层中性压实补平，整体读起来是连续的。"
            )
        }
        return AppLocalization.string(
            "这里调的是磨砂材质本身的不透明度：全区间连续，滑到哪就是哪，没有档位切换。"
        )
    }

    private var resetButton: some View {
        Button {
            // 「恢复默认」的目标值是用户拍板的 50，不是新装初始默认 30
            //（2026-10-15 拍板，见 `DisplayPreferences.resetGlassTransparency`）。
            store.glassTransparency = DisplayPreferences.resetGlassTransparency
        } label: {
            Text(AppLocalization.string("恢复默认"))
                .font(.app(15, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - 选择列表共用件

@MainActor
private func optionList<Content: View>(title: String,
                                       @ViewBuilder content: () -> Content) -> some View {
    ZStack {
        ThemedBackground()

        ScrollView {
            VStack(spacing: 6, content: content)
                .background(
                    Color.ncCard,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                )
                .padding(.horizontal, Tokens.Spacing.page)
                .padding(.top, 16)
        }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
}

@MainActor
private func optionRow(title: String,
                       subtitle: String? = nil,
                       isSelected: Bool,
                       accent: Color,
                       action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 12) {
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

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.app(14, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, Tokens.Spacing.row)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
