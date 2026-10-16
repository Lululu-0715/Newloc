import Foundation

/// 改写层证据账本：**「目标坐标确实喂进了系统」的铁证**。
///
/// ## 为什么需要它
///
/// 上一版校验只有两条证据：回读定位（问系统要位置）和链路探针（问代理要回显）。
/// 2026-10-13 用户 iOS 26 真机实测抓到死穴：**定位明明已经改了，回读却一直
/// 拿旧位置** —— `locationd` 的缓存对新请求不刷新，回读这条路在 iOS 26 上
/// 天然不可靠，于是校验永远停在「验证中」或冤判「系统未刷新」。
///
/// 这本账换了一个问法：**不去问系统认了没有，去问改写层干了什么。**
/// 改写层（内置代理 / 第三方脚本）每次真的把目标坐标写进定位响应，
/// 都会留下一条客观记录 —— 记录在案，就等于「目标坐标已经下发成功」，
/// 剩下的只是系统什么时候采用，而那不是本应用的锅。
///
/// ## 两个喂入口
///
/// - **内置代理**：Go 侧每次改写成功都打一条 `WLOC 已改写 …` 日志，
///   `CoreBridge.flushLogs` 每秒把日志搬进应用 —— 搬运路上顺手喂进这里。
///   不改 Go 一行代码。
/// - **第三方模式**：改写脚本每次运行都把结果写进诊断键（`wloc_diag`），
///   `ThirdPartyController` 回读诊断时顺手喂进这里。按时间戳去重：
///   同一次改写的诊断会被 probe 反复读到，不能重复记账。
///
/// ## 消费方
///
/// `SpoofEffectVerifier` 每轮校验先看这里：本轮开始**之后**出现了新记录，
/// 就向判定层发 `.rewriteObserved` 事件直接结案。账本是全局客观事实，
/// 不随校验轮次清空 —— 「本轮有没有新账」由校验器自己拿基线比对。
final class RewriteLedger: @unchecked Sendable {

    static let shared = RewriteLedger()

    /// 记账后发出的通知。**校验器靠它把「改写发生」变成事件驱动**：
    /// 旧实现只在自己的轮询节奏里看账本（最坏要等一轮探测 + 轮询间隔），
    /// 现在账一入簿立刻广播，校验器当帧结案 —— 改写发生到「已生效」
    /// 显示的全程只剩日志泵那一秒。
    static let didRecordNotification = Notification.Name("NewlocRewriteLedgerDidRecord")

    private let lock = NSLock()
    private var _lastRewriteAt: Date?
    private var _rewriteCount = 0

    /// 最近一次改写记账时刻。喂入方在任意线程（日志泵 / 探测回调），
    /// 读取也来自任意线程 —— 读写都过同一把锁。
    private(set) var lastRewriteAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _lastRewriteAt }
        set { lock.lock(); defer { lock.unlock() }; _lastRewriteAt = newValue }
    }
    private(set) var rewriteCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _rewriteCount }
        set { lock.lock(); defer { lock.unlock() }; _rewriteCount = newValue }
    }

    /// 第三方模式下去重用：`wloc_diag` 的 `ts`（毫秒）。
    /// probe 每次都把同一份诊断读回来，同一个 ts 只能记一次账。
    private var lastThirdPartyTs: TimeInterval = 0    /// 内置代理喂入口：解析一条 Go 日志行。
    ///
    /// 匹配 `proxy.go` 改写成功时打的固定前缀（`WLOC 已改写`）。
    /// 其余行（CONNECT、错误、验证请求）与改写无关，直接忽略。
    func observeBuiltinLogLine(_ line: String) {
        guard line.contains("WLOC 已改写") else { return }
        record()
    }

    /// 第三方模式喂入口：脚本诊断里的 `ts`（毫秒时间戳）。
    ///
    /// 只在 `outcome == "rewritten"` 时调用（调用方负责判断）。
    /// 时间戳与上次相同 = 同一份诊断被重复读回，跳过。
    func observeThirdPartyDiag(tsMilliseconds: TimeInterval) {
        lock.lock()
        let deduped = (tsMilliseconds > 0 && tsMilliseconds != lastThirdPartyTs)
        if deduped { lastThirdPartyTs = tsMilliseconds }
        lock.unlock()
        guard deduped else { return }
        record()
    }

    /// 清账。目前校验器用「基线比对」自防旧账误判，账本本身不必随轮次清；
    /// 保留这个方法给测试用（隔离用例间的账目）。
    func clear() {
        lock.lock()
        _lastRewriteAt = nil
        _rewriteCount = 0
        lastThirdPartyTs = 0
        lock.unlock()
    }

    private func record() {
        lastRewriteAt = Date()
        rewriteCount += 1

        // 广播在锁外：订阅者是同步回调，别让它堵着其他喂入方。
        NotificationCenter.default.post(name: Self.didRecordNotification, object: nil)
    }
}
