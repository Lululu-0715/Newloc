import Foundation

/// 「根证书到底被系统信任了没有」—— 一条**与 Wi-Fi 代理无关**的独立判据。
///
/// ## 为什么不能只看「描述文件装没装」
///
/// iOS 上安装描述文件只是把根证书**装进**系统，它还处在「未受完全信任」的状态。
/// 用户必须再进「设置 → 通用 → 关于本机 → 证书信任设置」，手动打开那个开关，
/// 证书才真正被信任。
///
/// 于是「装了但没开信任」是一个**极常见**的中间态，而界面上没有任何东西能区分
/// 它与「装好了」。用户会认为自己已经做完了一切，然后对着永远不生效的定位发火。
///
/// ## 怎么测
///
/// `certservice.go` 早就提供了答案：用 CA 签出一张 `127.0.0.1` 的叶子证书，
/// 起一个随机端口的 HTTPS 服务。**用默认参数请求 `/health` 是否握手成功**，
/// 就是「CA 已装且已信任」的完整判据 —— 完全不用去读系统信任设置。
///
/// 关键在于它**绕开 Wi-Fi 代理**：直连本机随机端口，不经过 8888。
/// 而链路探针（`LinkProbe`）恰好相反，它专测代理。两条证据各管一件事：
///
/// | 判据 | 回答的问题 |
/// |---|---|
/// | `/health` 握手（本类型） | 根证书信任了吗 |
/// | `LinkProbe` 回显 | Wi-Fi 代理配了吗、流量到我这儿了吗 |
struct CertificateTrustProbe {

    enum Verdict: Equatable {

        /// 握手成功 —— 系统完整信任了这张根证书。
        case trusted

        /// 握手被 TLS 层面拒绝 —— 证书装了但没打开信任开关，或者压根没装。
        case untrusted

        /// 没测成（CA 拿不到、服务起不来、网络层意外）。
        ///
        /// **与 `untrusted` 严格区分**：这里代表「不知道」，界面上应当保持
        /// 中性，不能报一个用户需要动手去修的状态。
        case unavailable

        var text: String {
            switch self {
            case .trusted:
                return AppLocalization.string("已信任")
            case .untrusted:
                return AppLocalization.string("未信任")
            case .unavailable:
                return AppLocalization.string("未检测")
            }
        }
    }

    private let authority: CertificateAuthority
    private let timeout: TimeInterval

    init(authority: CertificateAuthority = .shared, timeout: TimeInterval = 5) {
        self.authority = authority
        self.timeout = timeout
    }

    /// 实测一次。
    ///
    /// 每次都会起一个证书服务再关掉 —— 端口是系统随机分配的，所以重复调用
    /// 不会互相打架，也不需要维护长连接的生命周期。
    func check() async -> Verdict {
        let material: CertificateAuthority.Material
        do {
            material = try authority.loadOrCreate()
        } catch {
            AppLog.debug("证书", "无法取得根证书，信任检测跳过")
            return .unavailable
        }

        guard let handle = CoreBridge.startCertService(
            certificate: material.certificate,
            privateKey: material.privateKey
        ) else {
            AppLog.debug("证书", "证书服务未能启动，信任检测跳过")
            return .unavailable
        }
        defer { _ = CoreBridge.stopCertService(handle) }

        let port = CoreBridge.certServiceHTTPSPort(handle)
        guard port > 0, let url = URL(string: "https://127.0.0.1:\(port)/health") else {
            return .unavailable
        }

        let verdict = await request(url)
        // 记一条结果。诊断页上这条日志就是「证书到底信没信」的现场 ——
        // 用户说「我装了啊」的时候，只有它能说话。
        AppLog.info("证书", "根证书信任检测：\(Self.describe(verdict))")
        return verdict
    }

    static func describe(_ verdict: Verdict) -> String {
        switch verdict {
        case .trusted: return "已信任"
        case .untrusted: return "未信任"
        case .unavailable: return "未取得结果"
        }
    }

    private func request(_ url: URL) async -> Verdict {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout

        // **必须显式关掉代理。** 用户在 Wi-Fi 里配了 127.0.0.1:8888 之后，
        // 即便目标是本机 127.0.0.1，请求也会被送去那个代理，于是验到的证书
        // 变成代理动态签发的那张 —— 这一测就测不出根证书的真实信任状态了。
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
        ]

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.classify(statusCode: statusCode, body: String(data: data, encoding: .utf8) ?? "")

        } catch {
            return Self.classify(error as NSError)
        }
    }

    // MARK: - 分类
    //
    // 两段分类都抽成**静态纯函数**，理由一致：真实的检测要起临时 HTTPS 服务
    // 再发一次请求，而这里要验证的只是「哪种结果归哪一档」。这一档分类错了，
    // 界面就会把「没测成」当成「需要你去修」，反过来也一样。

    /// 按 HTTP 结果分类。
    static func classify(statusCode: Int, body: String) -> Verdict {
        guard statusCode == 200 else { return .unavailable }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "ok" ? .trusted : .unavailable
    }

    /// 按错误分类。
    ///
    /// **只有 TLS 层面的失败才算「未信任」。** 连不上、超时、DNS 出错都只是
    /// 「没测成」—— 把它们报成「未信任」会让用户反复去重装一张本来好端端的证书。
    static func classify(_ error: NSError) -> Verdict {
        // 复用链路探针那套 TLS 错误码判定 —— 同一件事只能有一套标准，
        // 各写一份迟早会出现「这里算拒绝、那里不算」。
        if LinkProbe.isTLSFailure(error) {
            AppLog.debug("证书", "握手被拒，根证书未被信任", details: [
                "code": String(error.code),
            ])
            return .untrusted
        }

        AppLog.debug("证书", "信任检测未取得结果", details: [
            "error": error.localizedDescription,
        ])
        return .unavailable
    }
}
