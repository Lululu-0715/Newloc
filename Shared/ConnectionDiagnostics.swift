import Combine
import Foundation

/// 「连接这一层到底通没通」的两条实测证据，供界面共享。
///
/// ## 为什么要收在一个对象里
///
/// 这两个结论都要花成本才能拿到 —— 证书信任检测要起一个临时 HTTPS 服务，
/// 链路检测要发一次真实请求。设置页、连接设置页、诊断页都要显示它们，
/// 各测各的就会在切页面时反复起服务、反复发请求。
///
/// ## 两条证据是**正交**的
///
/// | 证据 | 回答 | 与谁无关 |
/// |---|---|---|
/// | `trust`（`/health` 握手） | 根证书信任了吗 | Wi-Fi 代理 |
/// | `link`（回显 token） | 流量到我这儿了吗 | 证书是否被信任* |
///
/// \* 链路探针也会因证书未信任而 TLS 失败，但两者的错误码可区分，
/// 且**界面上的落点不同**：前者要用户去装证书，后者要用户去配 Wi-Fi 代理。
/// 把它们混成一句话，用户就不知道该动哪一头 —— 这正是 P2 拆分的出发点。
@MainActor
final class ConnectionDiagnostics: ObservableObject {

    static let shared = ConnectionDiagnostics()

    /// 根证书信任状态。
    @Published private(set) var trust: CertificateTrustProbe.Verdict = .unavailable

    /// 链路状态（改写有没有上路）。
    ///
    /// 只在内置代理运行时才有意义 —— 代理没跑时它必然是 `.unknown`，
    /// 界面应当据此显示「未检测」而不是「不通」。
    @Published private(set) var link: SpoofJudge.LinkEvidence = .unknown

    @Published private(set) var isRefreshing = false

    private let trustProbe: CertificateTrustProbe
    private let linkProbe: LinkProbe

    init(
        trustProbe: CertificateTrustProbe = CertificateTrustProbe(),
        linkProbe: LinkProbe = LinkProbe()
    ) {
        self.trustProbe = trustProbe
        self.linkProbe = linkProbe
    }

    /// 两项一起测。
    ///
    /// 三个 `refresh*` 都自己管闸门，共用 `check*` 私有实现 ——
    /// **不能**让公开方法互相调用：`refresh()` 里 `isRefreshing` 已经是 true，
    /// 再调 `refreshTrust()` 会被它自己的 guard 挡掉，第二项永远不测。
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await checkTrust()
        await checkLink()
    }

    /// 只测证书信任。
    ///
    /// ⚠️ 2026-10-15 审查 A6：这里原先**不设** `isRefreshing`，只有 `refresh()`
    /// 设 —— 而连接设置页两个「重新检测」按钮的 `isEnabled: !diagnostics.isRefreshing`
    /// 判的正是它。结果按钮**永远不会置灰**，检测中可连点，反复起临时 HTTPS 服务、
    /// 反复发链路请求，`refresh()` 里那句 `guard !isRefreshing` 也兜不到这两条路径。
    func refreshTrust() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await checkTrust()
    }

    /// 只测链路。
    func refreshLink() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await checkLink()
    }

    // MARK: - 实际检测（无闸门，只给上面三个公开方法用）

    private func checkTrust() async {
        trust = await trustProbe.check()
    }

    private func checkLink() async {
        guard CoreBridge.isProxyListening() else {
            link = .unknown
            return
        }
        link = await linkProbe.probe()
    }

    /// 代理关掉之后调用：链路证据必须跟着失效。
    ///
    /// **不清掉会撒谎** —— 上一次探测的 `.alive` 会一直挂在那儿，
    /// 而此刻代理可能已经关了。
    func invalidateLink() {
        link = .unknown
    }

    /// 证书重建之后调用：旧的信任结论作废。
    func invalidateTrust() {
        trust = .unavailable
    }
}
