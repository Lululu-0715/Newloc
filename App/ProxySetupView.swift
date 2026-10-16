import SwiftUI
import UIKit

/// 连接设置：把「代理能真正上路」所需的两件一次性配置走完。
///
/// ## 为什么这两件事要单独一页
///
/// 根证书和 Wi-Fi 代理都是**一次性资产** —— 配好之后日常使用只需要主界面
/// 那一个开关。把它们混进每日动线，用户每天都要面对一堆看不懂的配置项；
/// 藏进「设置」又太深，因为**第一次打开应用的人找不到它们就什么都做不成**。
///
/// ## 每一步都跟着实测结果
///
/// 三步证书流程 + 一步代理配置，每段右侧都有一个**实测**出来的状态：
/// 证书靠 `CertificateTrustProbe`（起一个临时 HTTPS 服务看握手），
/// 代理靠 `LinkProbe`（发一个带 token 的请求看回显）。
///
/// 没有实测结果，用户只能靠「我好像做过了」来判断 —— 而
/// **「装了描述文件但没打开信任开关」**这个中间态恰恰是看不出来的，
/// 界面必须替他说出来。
struct ProxySetupView: View {

    @Environment(\.dismiss) private var dismiss

    @StateObject private var proxy = ProxyController.shared
    @StateObject private var diagnostics = ConnectionDiagnostics.shared

    @State private var showRebuildConfirm = false
    @State private var showShutdownConfirm = false
    @State private var copied = false
    @State private var setupAlert: ProxyController.Alert?

    var body: some View {
        ZStack {
            ThemedBackground()

            ScrollView {
                VStack(spacing: 24) {
                    certificateGroup
                    wifiProxyGroup
                    serviceGroup
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
            // 进页面就把两项都测一遍 —— 用户来这儿就是要看「现在到底怎么样」。
            await diagnostics.refresh()
        }
        .alert(item: $setupAlert) { alert in
            Alert(title: Text(alert.failure.title),
                  message: Text(alert.failure.advice),
                  dismissButton: .default(Text(AppLocalization.string("知道了"))))
        }
        .confirmationDialog(
            AppLocalization.string("重建根证书？"),
            isPresented: $showRebuildConfirm,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("重建"), role: .destructive) { rebuildCertificate() }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("设备里已经装好的那张旧证书会立即失效，需要重新走一遍安装流程。"))
        }
        .confirmationDialog(
            AppLocalization.string("关闭代理服务？"),
            isPresented: $showShutdownConfirm,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("关闭"), role: .destructive) { proxy.shutdown() }
            Button(AppLocalization.string("取消"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("如果 Wi-Fi 里还配着本机代理，关闭后设备将无法联网。请同时到 Wi-Fi 设置里取消代理。"))
        }
    }

    // MARK: - ① 根证书

    private var certificateGroup: some View {
        SettingsGroup(title: AppLocalization.string("① 根证书")) {
            VStack(alignment: .leading, spacing: 0) {
                guideStep(number: "01",
                          title: AppLocalization.string("下载根证书"),
                          detail: AppLocalization.string("点下面的按钮，在 Safari 里保存证书文件。"))

                guideDivider

                guideStep(number: "02",
                          title: AppLocalization.string("安装描述文件"),
                          detail: SystemCompat.profileSettingsPath)

                guideDivider

                guideStep(number: "03",
                          title: AppLocalization.string("打开信任开关"),
                          detail: AppLocalization.string("设置 → 通用 → 关于本机 → 证书信任设置"))

                SettingsRowDivider()

                SettingsRow(systemImage: "checkmark.shield",
                            title: AppLocalization.string("当前状态"),
                            value: diagnostics.trust.text,
                            valueColor: trustColor)

                if diagnostics.trust == .untrusted {
                    SettingsRowDivider()
                    footnote(AppLocalization.string(
                        "证书已装但未开启信任。这是最常见的一步遗漏 —— 请到「证书信任设置」里打开它。"
                    ))
                }

                SettingsRowDivider()

                VStack(spacing: 9) {
                    PrimaryButton(title: AppLocalization.string("下载并安装根证书"),
                                  systemImage: "arrow.down.circle",
                                  height: 44) {
                        installCertificate()
                    }

                    HStack(spacing: 9) {
                        SecondaryButton(title: AppLocalization.string("重新检测"),
                                        systemImage: "arrow.clockwise",
                                        isEnabled: !diagnostics.isRefreshing,
                                        height: 38) {
                            Task { await diagnostics.refreshTrust() }
                        }

                        SecondaryButton(title: AppLocalization.string("重建证书"),
                                        height: 38) {
                            showRebuildConfirm = true
                        }
                    }
                }
                .padding(Tokens.Spacing.row)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private var trustColor: Color {
        switch diagnostics.trust {
        case .trusted: return .green
        case .untrusted: return StatusTint.ineffective.color
        case .unavailable: return Color.ncTextSecondary
        }
    }

    // MARK: - ② Wi-Fi 代理

    private var wifiProxyGroup: some View {
        SettingsGroup(title: AppLocalization.string("② Wi-Fi 代理")) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(systemImage: "server.rack",
                            title: AppLocalization.string("服务器"),
                            value: "127.0.0.1")

                SettingsRowDivider()

                SettingsRow(systemImage: "number",
                            title: AppLocalization.string("端口"),
                            value: String(ProxyController.port))

                SettingsRowDivider()

                footnote(AppLocalization.string(
                    "到「设置 → 无线局域网 → 当前网络的 (i) → 配置代理 → 手动」按上面的值填写。"
                ))

                SettingsRowDivider()

                SettingsRow(systemImage: "point.3.connected.trianglepath.dotted",
                            title: AppLocalization.string("当前状态"),
                            value: linkText,
                            valueColor: linkColor)

                if diagnostics.link == .tlsRejected {
                    SettingsRowDivider()
                    footnote(AppLocalization.string(
                        "流量已经走到代理，但证书没被信任 —— 请先完成上面的第 ① 步。"
                    ))
                }

                SettingsRowDivider()

                HStack(spacing: 9) {
                    SecondaryButton(title: copied
                                    ? AppLocalization.string("已复制")
                                    : AppLocalization.string("复制地址"),
                                    systemImage: copied ? "checkmark" : "doc.on.doc",
                                    height: 38) {
                        UIPasteboard.general.string = "127.0.0.1:\(ProxyController.port)"
                        copied = true
                    }

                    SecondaryButton(title: AppLocalization.string("重新检测"),
                                    systemImage: "arrow.clockwise",
                                    isEnabled: !diagnostics.isRefreshing,
                                    height: 38) {
                        Task { await diagnostics.refreshLink() }
                    }
                }
                .padding(Tokens.Spacing.row)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
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

    // MARK: - ③ 代理服务

    private var serviceGroup: some View {
        SettingsGroup(title: AppLocalization.string("③ 代理服务")) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(systemImage: "shield.lefthalf.filled",
                            title: AppLocalization.string("状态"),
                            value: serviceText,
                            valueColor: serviceColor)

                if let failure = proxy.failure {
                    SettingsRowDivider()
                    footnote(failure.advice)
                }

                SettingsRowDivider()

                footnote(AppLocalization.string(
                    "代理服务需要保持运行。若 Wi-Fi 里配着本机代理却把它关掉，设备将无法联网。"
                ))

                SettingsRowDivider()

                VStack(spacing: 9) {
                    SecondaryButton(title: proxy.status.isRunning
                                    ? AppLocalization.string("重启代理服务")
                                    : AppLocalization.string("启动代理服务"),
                                    systemImage: "power",
                                    height: 38) {
                        startService()
                    }

                    Button {
                        showShutdownConfirm = true
                    } label: {
                        Text(AppLocalization.string("关闭代理服务"))
                            .font(.app(15, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(
                                Color.red.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                     style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!proxy.status.isRunning)
                    .opacity(proxy.status.isRunning ? 1 : 0.4)
                }
                .padding(Tokens.Spacing.row)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
    }

    private var serviceText: String {
        switch proxy.status {
        case .stopped:
            return AppLocalization.string("已停止")
        case .starting:
            return AppLocalization.string("启动中…")
        case .running:
            return AppLocalization.string("运行中 · 端口 %@", String(ProxyController.port))
        case .failed(let failure):
            return failure.title
        }
    }

    private var serviceColor: Color {
        switch proxy.status {
        case .running: return .green
        case .starting: return StatusTint.verifying.color
        case .failed: return StatusTint.ineffective.color
        case .stopped: return Color.ncTextSecondary
        }
    }

    // MARK: - 动作

    /// 唤起 Safari 下载根证书。
    ///
    /// **为什么必须先把代理拉起来**：证书是通过代理的 `/cert` 端点吐出来的
    /// （端口固定 8888，也就是用户在 Wi-Fi 里要填的那个）。而且代理本来就应该
    /// 常驻 —— 用户来装证书，正是为了让这个代理能用。
    private func installCertificate() {
        do {
            try proxy.ensureListening()
        } catch let failure as ProxyController.Failure {
            setupAlert = ProxyController.Alert(failure: failure)
            return
        } catch {
            setupAlert = ProxyController.Alert(failure: .startFailed)
            return
        }

        guard let url = URL(string: "http://127.0.0.1:\(ProxyController.port)/cert") else { return }
        UIApplication.shared.open(url)
        AppLog.info("证书", "已唤起 Safari 安装根证书")
    }

    private func rebuildCertificate() {
        do {
            _ = try CertificateAuthority.shared.rebuild()
        } catch {
            AppLog.error("证书", "重建根证书失败")
            return
        }

        diagnostics.invalidateTrust()
        // 正在跑的代理手里还是旧 CA，必须重启才会换上新的一份。
        proxy.reloadCertificate()

        Task { await diagnostics.refreshTrust() }
    }

    private func startService() {
        do {
            if proxy.status.isRunning {
                // 运行中时按钮文案是「重启代理服务」，动作就必须真是**重启**。
                // `ensureListening()` 在已经监听时是空操作（`handle != nil &&
                // core.isProxyListening()` 直接 return），叫它等于什么都
                // 没做 —— 用户以为重启过（换证书、清状态），实际监听纹丝不动
                // （2026-10-15 审查 A5）。
                try proxy.restart()
            } else {
                try proxy.ensureListening()
            }
        } catch let failure as ProxyController.Failure {
            setupAlert = ProxyController.Alert(failure: failure)
            return
        } catch {
            setupAlert = ProxyController.Alert(failure: .startFailed)
            return
        }

        Task { await diagnostics.refreshLink() }
    }

    // MARK: - 小组件

    private func guideStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.app(12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.ncTextTertiary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.app(15))
                    .foregroundStyle(Color.ncText)

                Text(detail)
                    .font(.app(12))
                    .foregroundStyle(Color.ncTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.row)
        .padding(.vertical, 11)
    }

    private var guideDivider: some View {
        Divider().padding(.leading, Tokens.Spacing.row + 24)
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
