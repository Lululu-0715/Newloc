import SwiftUI

// MARK: - 运行模式设置（全能版独有）

/// 「设置 → 模式与连接 → 运行模式」：内置代理 / 第三方客户端二选一。
///
/// ⚠️ 路径写法要与界面一致：常驻入口在**设置页的「模式与连接」组**里，
/// 主界面上没有常驻的连接设置入口（那几个只会由告警或闸门提示临时唤起）。
/// 这里原来写「设置 → 运行模式」、脚注写「主界面 → 连接设置」，
/// 两处都指不到地方（2026-10-15 审查 B3）。
///
/// 客户端选择与模块安装引导**只留在连接设置页**（2026-10-13 用户要求）：
/// 那边本来就有同样的两组，这里再放一份是两处入口管同一件事，
/// 用户会困惑「改哪边才算数」。
///
/// 仅在 `THIRD_PARTY_MODE` 编译条件下存在（全能版 target）。
struct RunModeSettingsView: View {

    @ObservedObject private var modeStore = ModeStore.shared
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        ZStack {
            // 2026-10-14 补：此前裸 ScrollView 没有主题背景，深色主题下
            // 卡片颜色融进黑底 —— 用户实测「点进去啥都没有、没卡片」。
            ThemedBackground()

            ScrollView {
                // 2026-10-14 统一：顶部 16、组间距 24、左右走 Spacing.page(20)。
                VStack(spacing: 24) {
                    modeGroup
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("运行模式"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 模式二选一

    /// 行内图标宽度。**必须和下面 `Image(...).frame(width:)` 保持一致** ——
    /// 分隔线缩进靠它算（见 `modeRowTextLeading`）。
    private static let modeIconWidth: CGFloat = 24

    /// 卡片内正文的左边缘（相对卡片左边）：行内边距 + 图标宽 + 图标与文字间距。
    ///
    /// 不能用 `SettingsRowDivider`：它是按 36pt 图标章算的
    /// （`Tokens.Size.rowSeparatorInset` = 14 + 36 + 12 = 62），
    /// 而这一行的图标只有 24pt 宽，正文从 50 开始 —— 直接套会让分隔线
    /// 比正文还靠右 12pt（2026-10-14 用户实拍指出）。
    private var modeRowTextLeading: CGFloat {
        Tokens.Spacing.row + Self.modeIconWidth + Tokens.Spacing.rowIcon
    }

    private var modeGroup: some View {
        SettingsGroup(
            title: AppLocalization.string("运行模式"),
            footnote: modeStore.mode == .thirdParty
                ? AppLocalization.string("客户端与模块安装请到「设置 → 模式与连接 → 连接设置」。")
                : nil
        ) {
            ForEach([ModeStore.Mode.builtIn, .thirdParty], id: \.rawValue) { mode in
                if mode != .builtIn {
                    // 分隔线对齐正文左边缘（不用 SettingsRowDivider，理由见上）。
                    Divider().padding(.leading, modeRowTextLeading)
                }
                Button {
                    modeStore.mode = mode
                } label: {
                    HStack(spacing: Tokens.Spacing.rowIcon) {
                        Image(systemName: mode == .builtIn ? "wifi.router" : "arrow.triangle.swap")
                            .font(.app(15))
                            .foregroundStyle(themeAccent)
                            .frame(width: Self.modeIconWidth)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.app(15, weight: .medium))
                                .foregroundStyle(Color.ncText)

                            Text(mode == .builtIn
                                 ? AppLocalization.string("App 内置代理 + 根证书，装好即用")
                                 : AppLocalization.string("改写模块装在小火箭 / Surge 等客户端里，App 只写坐标"))
                                .font(.app(12))
                                .foregroundStyle(Color.ncTextSecondary)
                        }

                        Spacer(minLength: 0)

                        if modeStore.mode == mode {
                            Image(systemName: "checkmark")
                                .font(.app(14, weight: .semibold))
                                .foregroundStyle(themeAccent)
                        }
                    }
                    // 2026-10-14 补：这一行是自己画的 Button，此前只给了纵向
                    // 内边距，横向是 0 —— 文字顶到卡片左边、✓ 贴住卡片右边。
                    // 与其余所有卡片行统一走 Tokens.Spacing.row（14）。
                    .padding(.horizontal, Tokens.Spacing.row)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

}

// MARK: - 第三方模式的连接设置（全能版独有）

/// 第三方模式下的「连接设置」：模块检测 + 客户端匹配 + 安装引导。
///
/// 内置代理的证书 / Wi-Fi 代理配置与本模式无关（`ProxySetupView` 是内置专属），
/// 这页把「第三方没成功」拆成三个可看的实测状态 —— **模块通不通、
/// 客户端装没装、脚本有没有回读**，卡在哪一步一眼就能看到
/// （2026-10-12 用户实测第三方失败却无从下手，故加）。
struct ThirdPartySetupView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modeStore = ModeStore.shared
    @StateObject private var thirdParty = ThirdPartyController.shared
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 24) {
                    detectionGroup
                    clientGroup
                    if thirdParty.state == .active { notMovingGroup }
                    guideGroup
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("连接设置"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(AppLocalization.string("完成")) { dismiss() }
                    .font(.app(16, weight: .medium))
            }
        }
        .task {
            // 没探过就先探一次 —— 用户进来就是要看「现在到底通没通」。
            if thirdParty.state == .unknown { await thirdParty.probe() }
        }
    }

    // MARK: 模块检测

    private var detectionGroup: some View {
        SettingsGroup(title: AppLocalization.string("模块检测")) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(systemImage: "antenna.radiowaves.left.and.right",
                            title: AppLocalization.string("模块连通"),
                            value: thirdParty.statusText,
                            valueColor: moduleColor)

                SettingsRowDivider()

                SettingsRow(systemImage: "app.badge.fill",
                            title: AppLocalization.string("客户端"),
                            value: clientInstalledText,
                            valueColor: clientInstalled ? .green : StatusTint.ineffective.color)

                SettingsRowDivider()

                SettingsRow(systemImage: "doc.text.below.ecg",
                            title: AppLocalization.string("脚本回读"),
                            // 行上只放短结论（超长文案塞 value 会顶出卡片，
                            // 2026-10-13 实锤）；完整的引导/细节放组底说明段。
                            value: diagShortText,
                            valueColor: diagColor)

                if thirdParty.state == .unreachable, let error = thirdParty.lastError {
                    SettingsRowDivider()
                    footnote(error)
                }

                if let diagHint = diagFootnote {
                    SettingsRowDivider()
                    footnote(diagHint)
                }

                SettingsRowDivider()

                SecondaryButton(title: AppLocalization.string("重新检测"),
                                systemImage: "arrow.clockwise",
                                height: 38) {
                    Task { await thirdParty.probe() }
                }
                .padding(Tokens.Spacing.row)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private var moduleColor: Color {
        switch thirdParty.state {
        case .moduleIdle, .active: return .green
        case .unreachable: return StatusTint.ineffective.color
        case .unknown: return Color.ncTextSecondary
        }
    }

    /// 脚本回读的颜色：改写成功绿、被跳过/没匹配橙、还没触发过中性。
    private var diagColor: Color {
        guard let diag = thirdParty.lastDiag else { return Color.ncTextSecondary }
        switch (diag["outcome"] as? String) ?? "" {
        case "rewritten": return .green
        case "no-match", "gzip", "bad-target", "error": return StatusTint.ineffective.color
        default: return Color.ncTextSecondary
        }
    }

    /// 「脚本回读」行的**短结论** —— 行内 value 只放得下这几个字
    /// （超长文案塞 value 会顶出卡片边界，2026-10-13 截图实锤）。
    private var diagShortText: String {
        guard let diag = thirdParty.lastDiag else {
            return AppLocalization.string("还没触发过")
        }
        switch (diag["outcome"] as? String) ?? "" {
        case "rewritten": return AppLocalization.string("改写成功")
        case "no-match": return AppLocalization.string("没匹配到")
        case "gzip": return AppLocalization.string("gzip 未解压")
        case "disabled": return AppLocalization.string("未开启")
        case "bad-target": return AppLocalization.string("坐标无效")
        case "empty-body": return AppLocalization.string("响应为空")
        case "error": return AppLocalization.string("脚本报错")
        default: return AppLocalization.string("未知状态")
        }
    }

    /// 「脚本回读」的完整说明：无诊断时是触发引导，有诊断时把脚本
    /// 自己报的人话结论完整放在组底 —— 细节一条不丢，只是不挤 value。
    private var diagFootnote: String? {
        if thirdParty.lastDiag == nil {
            return AppLocalization.string(
                "改写脚本还没被触发过：开启虚拟定位后，让系统重新定位一次（打开地图 App）再看。")
        }
        return thirdParty.diagOutcomeText
    }

    /// 所选客户端装没装（scheme 白名单探测）。装没装模块要看连通那行 ——
    /// 客户端装了但模块没导入，连通依然是「未连接」。
    private var clientInstalled: Bool {
        guard let scheme = modeStore.client.openScheme,
              let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private var clientInstalledText: String {
        modeStore.client.displayName + " · "
            + AppLocalization.string(clientInstalled ? "已安装" : "未安装")
    }

    // MARK: 客户端选择

    /// 每行行尾都带「打开」小钮（2026-10-13 用户要求：不能有的客户端有
    /// 打开入口、有的没有 —— 六家统一放在行上，选完当场就能跳过去导入）。
    /// 行点击 = 选择；小钮点击 = 打开对应 App。两个手势不冲突（小钮先吃掉点击）。
    private var clientGroup: some View {
        SettingsGroup(title: AppLocalization.string("你的客户端")) {
            ForEach(ThirdPartyClient.allCases) { client in
                let index = ThirdPartyClient.allCases.firstIndex(of: client)
                if index ?? 0 > 0 { SettingsRowDivider() }
                HStack(spacing: 0) {
                    Button {
                        modeStore.client = client
                    } label: {
                        HStack {
                            Text(client.displayName)
                                .font(.app(16))
                                .foregroundStyle(Color.ncText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if modeStore.client == client {
                                Image(systemName: "checkmark")
                                    .font(.app(14, weight: .semibold))
                                    .foregroundStyle(themeAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // 行尾「打开」：图标 + 文字，六家恒显（scheme 全量白名单）。
                    if let url = URL(string: "\(client.openScheme ?? "")://") {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label(AppLocalization.string("打开"), systemImage: "arrow.up.forward.app")
                                .font(.app(13, weight: .medium))
                                .foregroundStyle(themeAccent)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 12)
                        .accessibilityLabel(
                            AppLocalization.string("打开%@", client.displayName))
                    }
                }
                // 与 SettingsRow 同一套水平边距与行高 —— 手写行缺了这一层
                // 文字会直接贴住卡片边缘，看着像「文字超出卡片」（2026-10-13 实锤）。
                .padding(.horizontal, Tokens.Spacing.row)
                .padding(.vertical, 14)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    // MARK: 安装引导

    // MARK: 定位没动排查

    /// 改写运行中但定位没动时的排查卡（2026-10-13 用户真机卡在这：
    /// 胶囊全绿、定位纹丝不动，App 里却没有任何一句话告诉他下一步做什么）。
    ///
    /// 核心事实：**「关开定位服务」这一招随系统版本变了** —— iOS ≤25 有效，
    /// iOS 26 起系统不再回应，只能重启设备。这条提示内置模式一直有
    ///（`SpoofState.advice` 已按版本分叉），第三方模式此前缺席。
    ///
    /// ⚠️ 2026-10-15 审查 B2：这里原先**只抄了 iOS 26 那一支**、
    /// 而且只要 `thirdParty.state == .active` 就无条件显示 —— 于是
    /// iOS 15~18 用户会读到「关开定位服务不再有效」，被逼去重启设备，
    /// 而那一招在他的系统上本来是**可用且最廉价**的解法。
    /// 现在与内置模式同口径，走 `SystemCompat`。
    private var notMovingGroup: some View {
        SettingsGroup(title: AppLocalization.string("定位没动？")) {
            VStack(alignment: .leading, spacing: 10) {
                footnote(notMovingSteps)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    /// 排查步骤。第 2 条按系统能力分叉，其余三条两版共用。
    ///
    /// 整段做成**两个完整键**而不是「片段拼接」：拼接会把句序、标点、编号
    /// 全压在调用点手里，翻译表反而更难维护 —— `SpoofState.advice` 也是
    /// 这个写法（整句分叉）。
    private var notMovingSteps: String {
        if SystemCompat.locationToggleFlushesCache {
            return AppLocalization.string(
                "改写已在运行。系统没换位置，按顺序试：\n"
                + "1. 回本应用点状态行的刷新验证（结论会写原因）；\n"
                + "2. 到「设置 → 隐私与安全性 → 定位服务」关一下再打开，即可刷新定位缓存；\n"
                + "3. 让系统发起一次全新定位：打开系统自带的「地图」App 看一眼位置；\n"
                + "4. 仍不行就回本页看「脚本回读」——改写成功、没匹配到、gzip 未解压都会写在这里。"
            )
        }
        return AppLocalization.string(
            "改写已在运行。系统没换位置，按顺序试：\n"
            + "1. 回本应用点状态行的刷新验证（结论会写原因）；\n"
            + "2. 系统从 iOS 26 起不再响应「关开定位服务」，需要重启设备才能刷新定位缓存；\n"
            + "3. 让系统发起一次全新定位：打开系统自带的「地图」App 看一眼位置；\n"
            + "4. 仍不行就回本页看「脚本回读」——改写成功、没匹配到、gzip 未解压都会写在这里。"
        )
    }

    private var guideGroup: some View {
        // 「打开客户端」不再放这里：客户端组每行行尾已有统一的打开入口，
        // 同一个按钮出现两处只会让人疑惑哪边才算数。
        SettingsGroup(title: AppLocalization.string("模块安装")) {
            NavigationLink {
                ModuleInstallGuideView()
            } label: {
                SettingsRow(systemImage: "square.and.arrow.down.on.square",
                            title: AppLocalization.string("模块安装引导"),
                            value: AppLocalization.string("导入地址与步骤"),
                            showsChevron: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.app(12))
            .foregroundStyle(Color.ncTextSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Spacing.row)
            .padding(.vertical, 10)
    }
}

// MARK: - 模块安装引导

/// 当前所选客户端的模块安装引导：复制导入地址 → 客户端里导入 → 开 MITM。
struct ModuleInstallGuideView: View {

    @ObservedObject private var modeStore = ModeStore.shared
    @Environment(\.themeAccent) private var themeAccent
    @State private var copied = false

    private var client: ThirdPartyClient { modeStore.client }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                clientHeader

                // 第 1 步：导入地址
                VStack(alignment: .leading, spacing: 10) {
                    stepTitle(1, AppLocalization.string("把导入地址粘进客户端的「添加模块 / 导入订阅」"))

                    HStack(spacing: 8) {
                        Text(client.importURL.absoluteString)
                            .font(.app(12).monospaced())
                            .foregroundStyle(Color.ncTextSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            UIPasteboard.general.string = client.importURL.absoluteString
                            copied = true
                        } label: {
                            Label(copied
                                  ? AppLocalization.string("已复制")
                                  : AppLocalization.string("复制"),
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.app(13, weight: .medium))
                                .foregroundStyle(themeAccent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }

                // 第 2 步起：逐条引导
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(client.installSteps.enumerated()), id: \.offset) { index, step in
                        stepRow(number: index + 2, text: step)
                    }
                }

                // MITM 与连通性提醒
                VStack(alignment: .leading, spacing: 8) {
                    Label(AppLocalization.string("两个常见坑"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(StatusTint.ineffective.color)

                    Text(AppLocalization.string("① 模块显示已启用但定位不动：多半是 MITM 没开或证书没信任 —— 改写必须在 HTTPS 解密下才生效。"))
                        .font(.app(12))
                        .foregroundStyle(Color.ncTextSecondary)
                    Text(AppLocalization.string("② 脚本拉不下来：导入地址要完整粘贴；刚更新过脚本的话，jsDelivr 缓存最长 12 小时。"))
                        .font(.app(12))
                        .foregroundStyle(Color.ncTextSecondary)
                }
                .padding(12)
                .background(
                    StatusTint.ineffective.color.opacity(StatusTint.fillOpacity),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .padding(.horizontal, Tokens.Spacing.page)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .navigationTitle(AppLocalization.string("模块安装引导"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let scheme = client.openScheme,
                   let url = URL(string: "\(scheme)://") {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Text(AppLocalization.string("打开客户端"))
                            .font(.app(14, weight: .medium))
                    }
                }
            }
        }
    }

    // MARK: 子件

    private var clientHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.swap")
                .font(.app(20))
                .foregroundStyle(themeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName)
                    .font(.app(17, weight: .semibold))
                    .foregroundStyle(Color.ncText)
                Text(AppLocalization.string("对应的模块文件：%@", client.moduleFile))
                    .font(.app(12))
                    .foregroundStyle(Color.ncTextSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func stepTitle(_ number: Int, _ text: String) -> some View {
        Text("\(number). \(text)")
            .font(.app(14, weight: .semibold))
            .foregroundStyle(Color.ncText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.app(12, weight: .semibold))
                .foregroundStyle(themeAccent)
                .frame(width: 20, height: 20)
                .background(
                    themeAccent.opacity(0.12),
                    in: Circle()
                )
            Text(text)
                .font(.app(13))
                .foregroundStyle(Color.ncText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}
