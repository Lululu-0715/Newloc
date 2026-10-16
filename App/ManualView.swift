import SwiftUI

/// 使用手册（设置 → 关于 → 使用手册）。
///
/// **三册闭环**（2026-10-15 用户拍板「太乱」后重构）：目录页三张卡 ——
/// ① 内置代理一条龙（装 → 配 → 开 → 关 → 排查）、② 第三方代理一条龙、
/// ③ 开发者模式说明（要不要开、怎么开、不开会怎样）。点卡片进详情页
/// 看该册全文。
///
/// 内容 = 两版草案合并（A「跟着做」+ B「速查」）：前半是顺序步骤，
/// 后半是速查 / 排查 / 名词表。文案仍走 `AppLocalization`（key = 简体中文），
/// en / zh-Hant 照常翻译；挂 `DisplayPreferences` 是为了让应用内切换语言时
/// 手册内容跟着重算。
struct ManualView: View {

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 24) {
                    ForEach(Array(ManualContent.sections.enumerated()),
                            id: \.element.id) { index, section in
                        NavigationLink {
                            ManualSectionDetail(section: section)
                        } label: {
                            ManualChapterRow(index: index, section: section)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("使用手册"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 章节行（目录页）

private struct ManualChapterRow: View {

    let index: Int
    let section: ManualSection

    var body: some View {
        HStack(spacing: 14) {
            Text("\(index + 1)")
                .font(.app(15, weight: .semibold))
                .foregroundStyle(Color.themeAccentValue)
                .frame(width: 30, height: 30)
                .background(
                    Color.themeAccentValue.opacity(0.12),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.app(16, weight: .medium))
                    .foregroundStyle(Color.ncText)
                    .multilineTextAlignment(.leading)

                Text(section.intro)
                    .font(.app(13))
                    .foregroundStyle(Color.ncTextSecondary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.app(13, weight: .semibold))
                .foregroundStyle(Color.ncTextSecondary.opacity(0.6))
        }
        .padding(Tokens.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.ncCard,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, Tokens.Spacing.page)
    }
}

// MARK: - 章节详情页

private struct ManualSectionDetail: View {

    let section: ManualSection

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                ManualSectionCard(section: section)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 内容模型

/// 手册的一节：标题 + 目录页一句话简介 + 若干内容块。
private struct ManualSection: Identifiable {
    let title: String
    let intro: String
    let blocks: [Block]

    var id: String { title }
}

/// 手册里的三种块：一段话 / 编号步骤 / 「问 → 答」对行。
private enum Block {
    case para(String)
    case steps([String])
    case pairs([(String, String)])
}

// MARK: - 单节卡片

private struct ManualSectionCard: View {

    let section: ManualSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.app(17, weight: .semibold))
                .foregroundStyle(Color.ncText)

            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .padding(Tokens.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.ncCard,
            in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        )
        .padding(.horizontal, Tokens.Spacing.page)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {

        case .para(let text):
            Text(text)
                .font(.app(14))
                .foregroundStyle(Color.ncTextSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

        case .steps(let items):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle().fill(Color.themeAccentValue.opacity(0.12))
                            Text("\(index + 1)")
                                .font(.app(12, weight: .semibold))
                                .foregroundStyle(Color.themeAccentValue)
                        }
                        .frame(width: 22, height: 22)

                        Text(item)
                            .font(.app(15))
                            .foregroundStyle(Color.ncText)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .pairs(let items):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pair.0)
                            .font(.app(15, weight: .medium))
                            .foregroundStyle(Color.ncText)

                        Text(pair.1)
                            .font(.app(14))
                            .foregroundStyle(Color.ncTextSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 9)

                    if index != items.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - 手册内容

@MainActor
private enum ManualContent {

    // 三册闭环（2026-10-15 用户拍板「太乱」）：内置代理、第三方代理各一条
    // 完整流程（装 → 配 → 开 → 关 → 排查），开发者模式单独一册说清要不要开。
    // 复用旧 key 的地方保持原文一致（en / zh-Hant 已有翻译），新增句子
    // 在 Localizable.strings 补翻译。
    static var sections: [ManualSection] {
        [
            // MARK: 第一册 · 内置代理
            ManualSection(title: AppLocalization.string("内置代理 · 从装到用"),
                          intro: AppLocalization.string("安装、配连接、开启、关闭，一条龙"), blocks: [
                .para(AppLocalization.string("适合：普通版。App 自带代理和根证书，装好即用。")),
                .steps([
                    AppLocalization.string("用侧载工具安装 ipa（爱思助手 / AltStore / Sideloadly 均可）。"),
                    AppLocalization.string("首次打开会弹定位授权，选「允许」——App 需要读真实位置来计算偏移。"),
                    AppLocalization.string("设置 → Wi-Fi → 当前网络 → 配置代理，选「手动」，服务器填 127.0.0.1，端口 8888。"),
                    AppLocalization.string("回 App「连接设置」下载根证书，再到系统 设置 → 通用 → VPN 与设备管理 安装，并在 关于本机 → 证书信任设置 里开启完全信任。"),
                    AppLocalization.string("回设置页确认：代理服务运行中、根证书已信任、Wi-Fi 代理已连通。"),
                    AppLocalization.string("在地图上点一下、搜个地名、或从收藏夹选一条。"),
                    AppLocalization.string("点主按钮「开启虚拟定位」，等结论变绿「已生效」。"),
                    AppLocalization.string("iOS 26 若提示「已生效 · 缓存未刷新」：重启一次设备立刻见效（系统缓存机制，不是 App 的问题）。"),
                    AppLocalization.string("用完：回 App 点「停止」，再把 Wi-Fi 代理改回「关闭」。"),
                ]),
                .para(AppLocalization.string("⚠️ 顺序别反：代理停了而 Wi-Fi 代理还挂着，手机会断网。真断网了别慌——重新打开本 App 就能恢复。")),
                .pairs([
                    (AppLocalization.string("全机断网"), AppLocalization.string("Wi-Fi 代理没关而代理停了；重新打开本 App，或把 Wi-Fi 代理改回关闭")),
                    (AppLocalization.string("定位一直没变"), AppLocalization.string("连接设置页三行没全绿；照本册第 3~5 步重新配")),
                    (AppLocalization.string("显示已生效，其他地图 App 还是旧位置"),
                     // ⚠️ 解法随系统版本变了（2026-10-15 审查 B4）：
                     // iOS ≤25 关开定位服务就能刷缓存，iOS 26 起只能重启设备。
                     SystemCompat.locationToggleFlushesCache
                        ? AppLocalization.string("定位缓存没刷新：到「设置 → 隐私与安全性 → 定位服务」关一下再打开")
                        : AppLocalization.string("定位缓存没刷新：系统从 iOS 26 起不再响应关开定位服务，需要重启设备")),
                    (AppLocalization.string("部分软件没网"), AppLocalization.string("对方检测代理或本 App 被系统挂起；第三方模式可根治")),
                    (AppLocalization.string("换个位置"), AppLocalization.string("地图点一下 / 搜索 / 收藏夹，重新开启")),
                    (AppLocalization.string("回真实位置"), AppLocalization.string("点「停止」")),
                ]),
            ]),

            // MARK: 第二册 · 第三方代理
            ManualSection(title: AppLocalization.string("第三方代理 · 从装到用"),
                          intro: AppLocalization.string("客户端装模块，免证书"), blocks: [
                .para(AppLocalization.string("适合：全能版。改写交给手机上已有的代理客户端（小火箭 / Surge 等），可覆盖蜂窝网络、不用装证书。")),
                .steps([
                    AppLocalization.string("用侧载工具安装 ipa（同内置代理那册），首次打开允许定位授权。"),
                    AppLocalization.string("设置 → 模式与连接 → 运行模式，选「第三方客户端」。"),
                    AppLocalization.string("在你的代理客户端里安装 Newloc 模块脚本（App 连接设置页可复制脚本、自动检测）。"),
                    AppLocalization.string("开启客户端，回 App 看「模块连通」变绿。"),
                    AppLocalization.string("在地图上点一下、搜个地名、或从收藏夹选一条。"),
                    AppLocalization.string("点主按钮「开启虚拟定位」，等结论变绿「已生效」。"),
                    AppLocalization.string("用完回 App 点「停止」即可，系统设置不用动。"),
                ]),
                .pairs([
                    (AppLocalization.string("第三方「模块未连接」"), AppLocalization.string("客户端没开 / 模块没装 / 脚本旧；连接设置页重新检测")),
                    (AppLocalization.string("显示已生效，其他地图 App 还是旧位置"),
                     SystemCompat.locationToggleFlushesCache
                        ? AppLocalization.string("定位缓存没刷新：到「设置 → 隐私与安全性 → 定位服务」关一下再打开")
                        : AppLocalization.string("定位缓存没刷新：系统从 iOS 26 起不再响应关开定位服务，需要重启设备")),
                    (AppLocalization.string("部分软件没网"), AppLocalization.string("第三方模式不再走系统代理，此问题可根治；若仍有，检查客户端规则是否放行该应用")),
                    (AppLocalization.string("换个位置"), AppLocalization.string("地图点一下 / 搜索 / 收藏夹，重新开启")),
                    (AppLocalization.string("回真实位置"), AppLocalization.string("点「停止」")),
                ]),
            ]),

            // MARK: 第三册 · 开发者模式
            ManualSection(title: AppLocalization.string("开发者模式说明"),
                          intro: AppLocalization.string("要不要打开，看这一篇就够"), blocks: [
                .para(AppLocalization.string("结论：用爱思助手 / AltStore / Sideloadly 这类工具侧载后，iOS 16 及以上需要打开「开发者模式」，否则 App 装完打不开。这是系统对开发类签名的强制要求，不是 App 的问题。iOS 15 及以下没有这个开关，不用管。")),
                .steps([
                    AppLocalization.string("设置 → 隐私与安全性 → 开发者模式 → 打开 → 按提示重启手机。"),
                    AppLocalization.string("如果找不到「开发者模式」这一项：先用数据线把手机连一次电脑（或等侧载工具装完第一次），系统才会显示这个开关。"),
                ]),
                .pairs([
                    (AppLocalization.string("不开会怎样"), AppLocalization.string("App 图标点了没反应，或提示「不受信任的开发者」——系统拦的是运行，不是 App 本身坏了。")),
                    (AppLocalization.string("平时要一直开着吗"), AppLocalization.string("用本 App 期间保持打开；关掉后已装的侧载 App 会被系统拦停。")),
                    (AppLocalization.string("App 打不开就是它吗"), AppLocalization.string("第一次装完就打不开，多半是开发者模式没开；用了几天才打不开，多半是签名过期，重新签一次。")),
                ]),
            ]),
        ]
    }
}
