import Combine
import CoreLocation
import Foundation
import SwiftUI

/// 生效校验的**驱动层**。
///
/// 职责只有三件事：**拿证据 → 喂给判定层 → 把结论抛出去**。
/// 判定规则一条都不在这里 —— 全在 `SpoofJudge.reduce`，那才是能穷举单测的地方。
///
/// 背景：定位服务把上一次的结果缓存（在系统进程里）很久，用户点「开启虚拟定位」
/// 之后地图上往往还是旧位置，得先让系统重新查询一次才会跳到选点。这一步做完
/// **到底成没成**，应用自己不吭声，用户只能盯着地图猜。
///
/// 怎么「让系统重新查询」**随系统版本变了**（见 `SystemCompat`）：iOS ≤ 25 是关开
/// 一次「定位服务」总开关，iOS 26+ 只能重启设备。所以驱动层必须容忍两件事：
///
///   1. 用户操作期间**总开关是关着的** —— 那几秒里 `authorizationStatus` 同样返回
///      `.denied`，不能当成「应用没有定位权限」结案；
///   2. 重启设备是**分钟级**的 —— 所以应用退到后台就**完全停掉循环**，
///      回前台再重新起一轮，而不是拿墙上时间做宽限。
@MainActor
final class SpoofEffectVerifier: ObservableObject {

    static let shared = SpoofEffectVerifier()

    // MARK: - 对外状态

    /// 当前结论。UI 只读这一个字段。
    @Published private(set) var state: SpoofState = .idle

    /// 确认生效的时刻（`state == .effective` 时有值）。
    @Published private(set) var verifiedAt: Date?

    /// 生效但只凭改写证据（回读从未命中）——系统缓存还没翻篇。
    ///
    /// UI 拿它决定要不要在「已生效」旁边附一句「地图还是旧位置的话，
    /// 重启设备可立即刷新」。这是提示不是警告：定位已经改了，
    /// 其余 App 看到的新位置就是证据。
    @Published private(set) var cacheStaleHint: Bool = false

    // MARK: - 内部

    private var judge = SpoofJudge.State()
    private let provider = RealLocationProvider()
    private let linkProbe = LinkProbe()
    private let settings = VerificationSettings.shared
    private var cancellables = Set<AnyCancellable>()

    /// 本轮校验开始时的改写账本基线。
    ///
    /// 账本（`RewriteLedger`）是全局客观事实，不随轮次清空；「本轮有没有
    /// 新改写」靠基线比对：每轮 `start` 时记下当时的账，`step` 里发现账本
    /// 走到了基线之后，才认定是**本轮目标**的改写 —— 上一轮的旧账不能
    /// 用来给新目标翻案。
    private var rewriteBaseline: Date?

    private var task: Task<Void, Never>?

    /// 是否在前台。退到后台就停循环，回前台重新起。
    private var isInForeground = true

    /// 两轮探测之间的间隔。
    ///
    /// 2026-10-13 从 3 秒压到 2 秒：校验是用户盯着看的过渡态，每快一秒
    /// 体验都实打实；探测本身（回读/链路）都在后台队列，2 秒不会压垮谁。
    private let interval: TimeInterval = 2

    /// 链路探针的最小间隔（秒）。
    ///
    /// 链路探针要发一次真实请求，比回读定位贵得多；而「代理在不在路上」
    /// 这件事变化不频繁。没必要每 3 秒问一遍。
    private static let linkProbeInterval: TimeInterval = 8
    private var lastLinkProbeAt: Date?

    private init() {
        // 总开关被拨动时重新评估：关掉应当**立即**停止循环，不能等下一轮。
        settings.$autoVerifyEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.autoVerifySettingChanged(enabled) }
            }
            .store(in: &cancellables)

        // 改写证据**事件驱动**（2026-10-13 提速）：账本一入簿立刻广播，
        // 这里当帧查看并结案。旧实现只在自己的轮询节奏里看账 —— 改写
        // 1 秒内就发生了，结案却可能要再等一轮探测加轮询间隔。
        // 这是「又快又准」的主通道：改写发生 → 日志泵入账（≤1 秒）→
        // 通知 → `.rewriteObserved` → 判定层直接结案 effective。
        NotificationCenter.default
            .publisher(for: RewriteLedger.didRecordNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleLedgerUpdate() }
            }
            .store(in: &cancellables)
    }

    /// 账本广播的响应：本轮开始之后出现的新账 = 本轮目标的改写，
    /// 直接结案。基线比对与 `step()` 的证据零共用同一套规则。
    private func handleLedgerUpdate() {
        guard judge.acceptsProbes,
              let last = RewriteLedger.shared.lastRewriteAt,
              last != rewriteBaseline else { return }
        rewriteBaseline = last
        apply(.rewriteObserved)
    }

    // MARK: - 配置

    /// 当前生效的判定配置。
    ///
    /// 总开关关着时把上限压到 1：**点一次仍然给一次结论，只是不再持续重试**。
    /// 这比「关掉就什么都不做」合理 —— 用户关的是自动轮询，不是这个功能。
    private var effectiveConfig: SpoofJudge.Config {
        var config = SpoofJudge.Config.standard
        if !settings.autoVerifyEnabled {
            config.maxProbes = 1
            config.linkObservationRounds = 1
        }
        return config
    }

    // MARK: - 对外控制

    /// 开始一轮校验（用户点了「开始定位」）。全新预算。
    func start(target: CLLocationCoordinate2D) {
        start(target: SpoofJudge.Coordinate(target), resumeBudget: false)
    }

    /// 手动触发一次重新校验。用户点的一律给全新预算。
    func reverify() {
        guard let target = judge.target else { return }
        AppLog.info("校验", "手动重新校验")
        start(target: target, resumeBudget: false)
    }

    /// 停止并回到未校验状态。
    func reset() {
        task?.cancel()
        task = nil
        apply(.reset)
    }

    /// - Parameter resumeBudget: true = 续用上一轮的探测预算（`probesUsed`
    ///   不清零）。**非用户发起**的重启（回前台自动重校验、自动校验开关
    ///   重新打开）必须传 true —— 否则用户每进出一次软件预算就重置一次，
    ///   状态机永远走不到终态，界面无限停在「验证中」（2026-10-13 用户实测）。
    private func start(target: SpoofJudge.Coordinate, resumeBudget: Bool) {
        let coldStart = Self.deviceRecentlyRebooted
        // 基线在发事件**之前**取：从这一刻起账本上新增的记录才算本轮的。
        // 换目标（targetChanged 清零 sawRewrite）时同理 —— 旧目标的改写
        // 账不能给新目标背书。
        if resumeBudget == false || judge.target != target {
            rewriteBaseline = RewriteLedger.shared.lastRewriteAt
        }
        apply(resumeBudget
              ? .resumed(target: target, coldStart: coldStart)
              : .started(target: target, coldStart: coldStart))

        AppLog.info("校验", resumeBudget ? "续开校验（预算保留）" : "开始校验虚拟定位", details: [
            "lat": String(format: "%.6f", target.latitude),
            "lon": String(format: "%.6f", target.longitude),
            "coldStart": coldStart ? "1" : "0",
            "autoVerify": settings.autoVerifyEnabled ? "1" : "0",
        ])

        drive()
    }

    // MARK: - 生命周期

    /// 由根视图把 `ScenePhase` 转进来。
    ///
    /// **`.inactive` 不算进过后台**：下拉通知中心、上滑控制中心、来电、
    /// 切到多任务预览都会走到 `.inactive`。把这些当暂停处理，会让校验
    /// 在这些场景下反复重启一轮，用户看到的是一直在「验证中」。
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let cameFromBackground = !isInForeground
            isInForeground = true
            if cameFromBackground { handleReturnToForeground() }

        case .background:
            isInForeground = false
            stopLoop()

        case .inactive:
            break

        @unknown default:
            break
        }
    }

    /// 回到前台后的处理。
    ///
    /// 几个「不做」都是有意的：
    ///   - 已经生效的不重跑 —— 那是个终态，重跑只会让稳定的结论开始闪烁；
    ///   - **已有非暂态结论的不重跑**（2026-10-13 修复）：上一版只要不是
    ///     `.effective` 就重开，结果「系统没刷新」的结论每次回前台都被推翻，
    ///     校验无限打转，用户看到的就是一直在「验证中」。例外是设备
    ///     刚重启过 —— iOS 26 的解锁动作就是重启，重启回来系统缓存已刷，
    ///     值得给一轮全新校验；
    ///   - 总开关关着不做 —— 用户明确说了不要自动校验；
    ///   - 用户单独关了「回前台重校验」也不做。
    private func handleReturnToForeground() {
        guard settings.autoVerifyEnabled, settings.reverifyOnForeground else { return }
        guard let target = judge.target else { return }

        if judge.isTerminal {
            guard Self.deviceRecentlyRebooted else { return }
            AppLog.info("校验", "设备刚重启，回前台重新校验")
            start(target: target, resumeBudget: false)
            return
        }

        AppLog.info("校验", "回到前台，续开校验")
        start(target: target, resumeBudget: true)
    }

    private func autoVerifySettingChanged(_ enabled: Bool) {
        if enabled {
            // 刚打开：如果手上还有目标，接着校验（续用预算，理由同上）。
            if let target = judge.target, judge.publicState != .effective {
                AppLog.info("校验", "自动校验已开启，继续校验")
                start(target: target, resumeBudget: true)
            }
        } else {
            AppLog.info("校验", "自动校验已关闭")
            // 正在跑的那一轮停掉；已经拿到的结论保留（不清成 idle）。
            stopLoop()
        }
    }

    // MARK: - 驱动循环

    private func stopLoop() {
        task?.cancel()
        task = nil
    }

    private func drive() {
        stopLoop()

        task = Task { [weak self] in
            while true {
                if Task.isCancelled { return }
                guard let self else { return }

                // 退到后台 → **直接结束循环**，不是 sleep 空转。
                // 用户这会儿多半在系统设置里操作，或者在等设备重启，
                // 计时毫无意义；回前台时会重新起一轮。
                if !self.isInForeground { return }

                await self.step()

                if Task.isCancelled { return }
                if self.judge.isTerminal { return }

                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    /// 一轮：拿四份证据，依次喂给判定层。
    private func step() async {
        guard judge.acceptsProbes else { return }

        // 证据零：改写层流水（2026-10-13 换证据源）。
        //
        // 放在最前：账上有本轮新改写 = 坐标已下发成功，直接结案，
        // 连总开关、链路、回读都不必再问 —— 省电，更重要的是**快**：
        // 改写发生到日志落账只隔一次日志泵（1 秒），比等回读解算快得多。
        // iOS 26 缓存不刷新时这条是唯一的翻案通道。
        if let last = RewriteLedger.shared.lastRewriteAt, last != rewriteBaseline {
            rewriteBaseline = last
            apply(.rewriteObserved)
            if judge.isTerminal { return }
        }

        // 证据一：系统定位服务总开关。
        //
        // **必须先问这个** —— `.denied` 在总开关关着时也会出现，
        // 不先分辨，用户按引导去关开关的那几秒就会被误判成「没有权限」。
        let servicesOn = await RealLocationProvider.systemServicesEnabled()
        apply(.servicesEnabled(servicesOn))

        // 证据二：链路（改写有没有上路）。带节流，且一旦有结论就不重探。
        if shouldProbeLink() {
            lastLinkProbeAt = Date()
            let evidence = await linkProbe.probe()
            apply(.link(evidence))
        }

        // 证据三：回读定位。
        guard judge.acceptsProbes else { return }
        if servicesOn {
            let outcome = await probeOnce()
            apply(.probe(outcome))
        }
    }

    private func shouldProbeLink() -> Bool {
        switch judge.linkEvidence {
        case .alive, .tlsRejected:
            // 已有结论，本轮不必重探。
            return false
        case .unknown:
            guard let last = lastLinkProbeAt else { return true }
            return Date().timeIntervalSince(last) >= Self.linkProbeInterval
        }
    }

    /// 把回调式的 `requestOnce` 包成 async，**并且加一层超时**。
    ///
    /// 超时这一层不是可选项：`CLLocationManager` 在拿不到定位时不保证回调
    /// （授权已给但系统解不出来、模拟器里没有位置源、`locationd` 正在重启），
    /// 而 `withCheckedContinuation` 会一直挂着 —— 整个驱动循环就卡死在那儿，
    /// 界面永远停在「验证中」。判定层保证「到上限必给结论」，
    /// 但那个前提是**探测真的能返回**。
    ///
    /// 超时按 `.unavailable` 处理：它表示「这一轮没拿到证据」，
    /// 而不是「没有权限」，下一次探测还会继续，到上限自然会收口。
    ///
    /// 8 → 6 秒（2026-10-13）：`requestLocation` 正常在数秒内返回，
    /// 拖到 8 秒还不回的枪基本是解不出来的 —— 早断早轮转，别让一枪
    /// 失败占住整个循环节奏。
    private func probeOnce(timeout: TimeInterval = 6) async -> SpoofJudge.ProbeOutcome {
        await withCheckedContinuation { continuation in
            // 回调与超时会赛跑，必须保证 continuation 只被 resume 一次 ——
            // 重复 resume 会直接崩掉进程。
            let resumed = ResumeGuard()

            provider.requestOnce(forceFresh: true) { result in
                guard resumed.claim() else { return }
                switch result {
                case .success(let coordinate):
                    continuation.resume(returning: .located(SpoofJudge.Coordinate(coordinate)))
                case .failure(.denied):
                    continuation.resume(returning: .denied)
                case .failure(.restricted):
                    continuation.resume(returning: .restricted)
                case .failure(.unavailable):
                    continuation.resume(returning: .unavailable)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                AppLog.debug("校验", "回读定位超时，本轮按未取到证据处理")
                continuation.resume(returning: .unavailable)
            }
        }
    }

    // MARK: - 落状态

    private func apply(_ event: SpoofJudge.Event) {
        let before = judge.publicState
        judge = SpoofJudge.reduce(judge, event, config: effectiveConfig)
        let after = judge.publicState

        state = after
        verifiedAt = judge.verifiedAt
        cacheStaleHint = judge.effectiveWithStaleCache

        if before != after {
            logTransition(from: before, to: after)
        }

        // 终态出现（事件驱动的 `.rewriteObserved` 会在探测还挂着的半路结案）
        // 立刻停循环 —— 不等 while 下一轮的 isTerminal 检查，也不让
        // `Task.sleep` 白白把循环吊着。
        if judge.isTerminal {
            stopLoop()
        }
    }

    private func logTransition(from before: SpoofState, to after: SpoofState) {
        let details = [
            "from": Self.describe(before),
            "to": Self.describe(after),
            "probes": "\(judge.probesUsed)",
            "link": Self.describe(judge.linkEvidence),
        ]

        switch after {
        case .effective:
            AppLog.info("校验", "虚拟定位已生效", details: details)
        case .ineffective(let reason):
            AppLog.warn("校验", "校验给出结论：\(reason.text)", details: details)
        case .idle, .verifying:
            AppLog.debug("校验", "状态变化 \(Self.describe(before)) → \(Self.describe(after))",
                         details: details)
        }
    }

    private static func describe(_ state: SpoofState) -> String {
        switch state {
        case .idle: return "idle"
        case .verifying: return "verifying"
        case .effective: return "effective"
        case .ineffective(let reason):
            switch reason {
            case .systemServicesOff: return "servicesOff"
            case .permissionDenied: return "permissionDenied"
            case .restricted: return "restricted"
            case .proxyUnreachable: return "proxyUnreachable"
            case .systemNotResolved: return "systemNotResolved"
            }
        }
    }

    private static func describe(_ evidence: SpoofJudge.LinkEvidence) -> String {
        switch evidence {
        case .unknown: return "unknown"
        case .alive: return "alive"
        case .tlsRejected: return "tlsRejected"
        }
    }

    // MARK: - 冷启动

    /// 设备是否刚重启过。
    ///
    /// 用系统开机时长判断，而不是「应用是不是第一次启动」—— 后者判断的是
    /// 应用自己的生命周期，与我们要防的问题无关。
    ///
    /// **为什么要防**：iOS 26+ 刷定位缓存必须重启设备，所以「重启后立刻
    /// 打开应用」是最常见的一条路径。此时 `locationd` 自己也在初始化，
    /// 前几枪拿到的 `.denied` 是冤枉的。
    private static var deviceRecentlyRebooted: Bool {
        ProcessInfo.processInfo.systemUptime < 300
    }
}

/// 「只允许第一个到的人通过」的一次性闸门。
///
/// 回调路径和超时路径会赛跑，而 `CheckedContinuation` **重复 resume 会崩进程**。
/// 用它把两条路收敛到一次。
private final class ResumeGuard: @unchecked Sendable {

    private var claimed = false
    private let lock = NSLock()

    /// 抢占。只有第一次返回 true。
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
