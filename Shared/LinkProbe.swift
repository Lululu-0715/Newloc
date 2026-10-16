import Foundation

/// 链路探针：**改写有没有上路**。
///
/// 这是与「回读到什么位置」**相互独立**的第二条证据。上一代只用回读定位
/// 一条判据，同时回答「代理通了吗」和「系统认了吗」两个不同的问题 ——
/// 于是用户拿到一条「请确认代理已开启、证书已信任」的提示，
/// 却不知道到底该去查哪一头。
///
/// 做法（沿用上一代，它是对的）：向代理发一个带一次性 token 的请求，
/// 代理把它拦下并回显 token。**这个请求根本到不了真正的服务器** ——
/// 它被本机代理截住了。所以「回显对上了」这件事本身就证明请求确实
/// 经过了本机代理，而不是一个有外部依赖的连通性测试。
///
/// - Note: 链路探针只在**内置代理**模式下有意义。第三方模式下改写脚本装在
///   用户自己的客户端里，本应用没有可用的回显通道 —— 此时探针恒返回
///   `.unknown`，校验退化成只有结果证据的形态（见 `docs/05` 决策四）。
struct LinkProbe {

    struct Config: Equatable {

        /// 代理监听地址。**必须与 Go 侧保持一致**。
        var host: String = "127.0.0.1"
        var port: Int = 8888

        /// 探针超时。太短会在代理冷启动时误报，太长会把校验循环拖住。
        var timeout: TimeInterval = 5

        static let standard = Config()
    }

    private let config: Config

    init(config: Config = .standard) {
        self.config = config
    }

    /// 探针之间的互斥闸门。**全局一份**，所有 `LinkProbe` 实例共用。
    ///
    /// 原因见 `AsyncMutex` 的文档 —— 验证 token 在 Go 侧是全局单例，
    /// 并发探测会互相把对方的 token 踩掉。
    private static let serializer = AsyncMutex()

    /// 探一次链路。
    ///
    /// 与其它探针**串行**执行，原因见 `AsyncMutex`。
    func probe() async -> SpoofJudge.LinkEvidence {
        await Self.serializer.acquire()
        let evidence = await performProbe()
        Self.serializer.release()
        return evidence
    }

    private func performProbe() async -> SpoofJudge.LinkEvidence {

        // 代理根本没在监听 → 连请求都不必发。
        //
        // 这里返回 `.unknown` 而**不是** `.tlsRejected`：现状是「还没起来」，
        // 不是「证书被拒」。报错方向错了，用户会跑去重装证书，白忙一场。
        guard CoreBridge.isProxyListening() else {
            AppLog.debug("链路", "代理未在监听，链路证据暂缺")
            return .unknown
        }

        let token = CoreBridge.refreshVerifyToken()
        guard !token.isEmpty,
              let url = URL(string: "https://www.baidu.com/location-verify-\(token)") else {
            return .unknown
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": config.host,
            "HTTPPort": config.port,
            "HTTPSEnable": 1,
            "HTTPSProxy": config.host,
            "HTTPSPort": config.port,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, _) = try await session.data(for: request)
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.trimmingCharacters(in: .whitespacesAndNewlines) == token {
                AppLog.debug("链路", "代理链路验证通过")
                return .alive
            }
            // 请求过去了、但没被回显 —— 多半走到了真实服务器。
            AppLog.debug("链路", "代理链路未生效（回显内容不匹配）")
            return .unknown

        } catch {
            let nsError = error as NSError
            if Self.isTLSFailure(nsError) {
                AppLog.warn("链路", "代理 TLS 握手失败", details: [
                    "code": String(nsError.code),
                ])
                return .tlsRejected
            }
            AppLog.debug("链路", "代理链路未生效", details: [
                "error": nsError.localizedDescription,
            ])
            return .unknown
        }
    }

    /// 判断一个 `URLSession` 错误是否属于「TLS 层面被拒」。
    ///
    /// 这条判断是**证据驱动**的落点：是否被系统封了，只能由实测的握手结果
    /// 说话，不能由版本号推断 —— iOS 27 的 beta 1~5 是可用区间，
    /// 写成「27 就报错」会把它们一起误伤。版本号只用来决定文案措辞。
    static func isTLSFailure(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return true
        default:
            return false
        }
    }
}

/// 一次只放一个通过的**异步**互斥闸门。
///
/// ## 为什么需要它
///
/// 链路探针的验证 token 在 Go 侧是**全局单例槽位** ——
/// `locationcore_refreshverifytoken` 每调一次就把上一个覆盖掉。两个探针并发时：
///
/// ```
/// 探针 A：refresh → token-1，Go 侧当前 token = token-1
/// 探针 B：refresh → token-2，Go 侧当前 token = token-2   ← 把 A 的踩了
/// 探针 A 的请求到达代理 → 拿 token-1 比对 token-2 → 对不上 → 原样放行
/// 探针 A：回显内容不匹配 → 判定「链路未生效」              ← 假的！
/// ```
///
/// 这不是推演，是实测抓到的：App 启动时主界面的连接诊断与「回前台恢复代理」
/// 各探了一次，后者因此误判并白白重启了一遍代理。
///
/// ## 为什么不用 actor
///
/// actor 的方法在 `await` 处会**重入** —— 而这里要保护的恰恰是一段跨越
/// `await` 的临界区（生成 token → 发请求 → 比对回显）。重入意味着第二个调用
/// 能在第一个还挂在 `session.data` 上时进来，闸门形同虚设。
///
/// ## 为什么不用 NSLock 直接包住临界区
///
/// 临界区跨 `await`，持锁等待会阻塞线程甚至死锁。这里的锁**只保护等待队列本身**，
/// 排队通过 `CheckedContinuation` 挂起，不占线程。
final class AsyncMutex: @unchecked Sendable {

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    /// 同步临界区助手。
    ///
    /// 为什么不直接写 `lock.lock()` / `lock.unlock()`：这两个方法在 Swift 里
    /// 标了 `noasync` —— 在**异步函数体**里直接调用会被判为错误
    /// （Swift 5 语言模式下是警告，Swift 6 下直接编译不过）。
    /// 包一层同步函数就绕开了：警告只针对「异步上下文里直接调用」这一种写法，
    /// 而下面这个方法本身是同步的。
    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func acquire() async {
        // 快路径：没人持有就直接拿走，连 continuation 都不建。
        let available = withLock { () -> Bool in
            guard !isBusy else { return false }
            isBusy = true
            return true
        }
        if available { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 「直接拿走」与「登记排队」必须在**同一次持锁**里决出。
            //
            // 不能写成「先持锁看一眼 → 放锁 → 再持锁登记」：持有者可能正好在
            // 这两步之间 `release`，那时队列还是空的，通行证就这样被丢弃，
            // 随后登记进去的等待者永远醒不来 —— 表现为「32 个任务只跑完 31 个」，
            // 最后一个把测试挂到超时。这个窗口很窄，但它是真的。
            let granted = withLock { () -> Bool in
                guard !isBusy else {
                    waiters.append(continuation)
                    return false
                }
                isBusy = true
                return true
            }
            // `resume` 放在锁**外**：被唤醒的任务若恰好在本线程上恢复执行，
            // 会立刻回来再碰这把锁，而 `NSLock` 不可重入。
            if granted { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = withLock {
            guard !waiters.isEmpty else {
                isBusy = false
                return nil
            }
            // 把「通行证」直接交给下一个等待者 —— `isBusy` 保持 true，
            // 因为从这一刻起换它持有了。
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
