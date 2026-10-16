import SwiftUI

/// 诊断页：环境自检 + 运行日志。
///
/// **为什么日志要做得这么显眼**：上一代的排查过程里，最难的一步是
/// 「拿不到现场」—— 用户说「复制不过来」，而日志又恰恰是判断
/// 「证书是否被系统拒绝」的唯一证据。所以这里：
///   * 提供**一键复制**；
///   * 提供**问题报告**（把设备与运行环境一起带上）；
///   * 正文开 `textSelection`，复制按钮不灵也能长按手选。
struct DiagnosticsView: View {
    @StateObject private var proxy = ProxyController.shared
    @StateObject private var diagnostics = ConnectionDiagnostics.shared
    #if THIRD_PARTY_MODE
    @StateObject private var modeStore = ModeStore.shared
    @StateObject private var thirdParty = ThirdPartyController.shared
    #endif
    @State private var entries: [AppLog.Entry] = []
    @State private var copied = false

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 24) {
                    actionRow
                    environmentCard
                    logCard
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(AppLocalization.string("诊断"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = AppLog.shared.snapshot }
        .task {
            // 连接状态要实测，实测过程本身会产生日志（起了临时服务、发了探测），
            // 所以这里测完再读一次快照。
            await diagnostics.refresh()
            #if THIRD_PARTY_MODE
            if modeStore.mode == .thirdParty, thirdParty.state == .unknown {
                await thirdParty.probe()
            }
            #endif
            entries = AppLog.shared.snapshot
        }
    }

    // MARK: - 操作

    /// 改写账本的人话摘要。
    ///
    /// 时间只显示到分秒 —— 它是「最近一次真的改写过」的凭证，
    /// 不是给用户排时间线用的。
    private var rewriteLedgerText: String {
        let ledger = RewriteLedger.shared
        guard ledger.rewriteCount > 0, let last = ledger.lastRewriteAt else {
            return AppLocalization.string("暂无记录")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return AppLocalization.string("已下发 %ld 次 · 最近 %@", ledger.rewriteCount,
                                      formatter.string(from: last))
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            SecondaryButton(title: copied
                            ? AppLocalization.string("已复制")
                            : AppLocalization.string("复制日志"),
                            systemImage: copied ? "checkmark" : "doc.on.doc",
                            height: 38) {
                UIPasteboard.general.string = AppLog.shared.exportText()
                copied = true
            }

            SecondaryButton(title: AppLocalization.string("清空"),
                            systemImage: "trash",
                            height: 38) {
                AppLog.shared.clear()
                entries = []
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    // MARK: - 环境

    private var environmentCard: some View {
        SettingsGroup(title: AppLocalization.string("运行环境")) {
            SettingsRow(systemImage: "iphone",
                        title: AppLocalization.string("系统版本"),
                        value: SystemCompat.versionDescription)
            SettingsRowDivider()
            SettingsRow(systemImage: "arrow.triangle.2.circlepath",
                        title: AppLocalization.string("缓存刷新方式"),
                        value: SystemCompat.locationToggleFlushesCache
                            ? AppLocalization.string("关开定位服务")
                            : AppLocalization.string("重启设备"))
            SettingsRowDivider()
            // 下面几行都是**实测**结果，不是读配置得来的 —— 诊断页的价值全在于此。
            thirdPartyEnvironmentRows
            SettingsRow(systemImage: "shield.lefthalf.filled",
                        title: AppLocalization.string("代理服务"),
                        value: proxyText,
                        valueColor: proxyColor)
            SettingsRowDivider()
            SettingsRow(systemImage: "checkmark.shield",
                        title: AppLocalization.string("根证书"),
                        value: diagnostics.trust.text)
            SettingsRowDivider()
            SettingsRow(systemImage: "point.3.connected.trianglepath.dotted",
                        title: AppLocalization.string("Wi-Fi 代理"),
                        value: linkText)
            SettingsRowDivider()
            // 改写层证据（2026-10-13）：改写是校验器判「已生效」的第一证据，
            // 把它亮出来 —— 用户怀疑「校验怎么过的」时有账可查。
            SettingsRow(systemImage: "paperplane.fill",
                        title: AppLocalization.string("位置下发"),
                        value: rewriteLedgerText,
                        valueColor: RewriteLedger.shared.rewriteCount > 0 ? .green : Color.ncTextSecondary)
            SettingsRowDivider()
            SettingsRow(systemImage: "number",
                        title: AppLocalization.string("日志条数"),
                        value: "\(entries.count)")
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    /// 第三方模式的链路体检（全能版 + 第三方模式才出现）：
    /// 模块连通与所选客户端。内置模式的行隐藏，避免两套结论混在一起打架。
    @ViewBuilder
    private var thirdPartyEnvironmentRows: some View {
        #if THIRD_PARTY_MODE
        if modeStore.mode == .thirdParty {
            SettingsRow(systemImage: "antenna.radiowaves.left.and.right",
                        title: AppLocalization.string("模块连通"),
                        value: thirdParty.statusText,
                        valueColor: thirdParty.state == .moduleIdle || thirdParty.state == .active
                            ? .green
                            : (thirdParty.state == .unreachable ? StatusTint.ineffective.color : Color.ncTextSecondary))
            SettingsRowDivider()
            SettingsRow(systemImage: "app.badge.fill",
                        title: AppLocalization.string("客户端"),
                        value: modeStore.client.displayName)
            SettingsRowDivider()
        }
        #endif
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

    private var linkText: String {
        switch diagnostics.link {
        case .alive: return AppLocalization.string("已连通")
        case .tlsRejected: return AppLocalization.string("证书未受信任")
        case .unknown: return AppLocalization.string("未检测")
        }
    }

    // MARK: - 日志

    private var logCard: some View {
        SettingsGroup(title: AppLocalization.string("运行日志")) {
            if entries.isEmpty {
                Text(AppLocalization.string("暂无日志。"))
                    .font(.app(14))
                    .foregroundStyle(Color.ncTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Spacing.row)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.reversed()) { entry in
                        logRow(entry)
                        if entry.id != entries.first?.id {
                            Divider().padding(.leading, Tokens.Spacing.row)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private func logRow(_ entry: AppLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(timeText(entry.date))
                    .font(.app(11, design: .monospaced))
                    .foregroundStyle(Color.ncTextTertiary)

                Text(entry.level.rawValue)
                    .font(.app(11, weight: .medium))
                    .foregroundStyle(color(for: entry.level))

                Text(entry.category)
                    .font(.app(11))
                    .foregroundStyle(Color.ncTextSecondary)
            }

            Text(entry.message)
                .font(.app(13))
                .foregroundStyle(Color.ncText)
                .fixedSize(horizontal: false, vertical: true)

            if !entry.details.isEmpty {
                Text(entry.details.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: ", "))
                    .font(.app(11, design: .monospaced))
                    .foregroundStyle(Color.ncTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Spacing.row)
        .padding(.vertical, 9)
        // 复制按钮万一失灵，用户还能长按手选。
        .textSelection(.enabled)
    }

    private func color(for level: AppLog.Level) -> Color {
        switch level {
        case .debug: return .ncTextTertiary
        case .info: return .ncTextSecondary
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
