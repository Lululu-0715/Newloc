import CoreLocation
import Foundation

/// 「虚拟定位到底生效了没有」的**纯判定层**。
///
/// 这一层里没有 async、没有 IO、没有单例、没有 `@MainActor` ——
/// 只有 `(状态, 事件) -> 状态`。
///
/// **为什么要拆出这一层**：上一代把同一套规则写在一个 90 行的 async 循环里，
/// 什么时候结案、什么时候重试、什么时候暂停，全揉在 `while` + `switch` 的
/// 控制流里。后果是单测只能测「整轮跑完的最终状态」，**测不到中间的迁移** ——
/// 那个「切后台再回来不重新校验」的回归就是这么漏出去的。
///
/// 拆开之后，规则变成一张可以逐格填满的表（见 `reduce` 里的 R1~R9），
/// 任何输入序列都能在毫秒内跑完，不需要真机、不需要等 30 秒。
///
/// 真正的 IO（回读定位 / 探总开关 / 探链路）在 `SpoofEffectVerifier` 里，
/// 它只负责把观察到的**事件**喂进来，然后把 `publicState` 拿去展示。
enum SpoofJudge {

    // MARK: - 坐标

    /// 判据里用的坐标。
    ///
    /// 单独包一层而不是直接用 `CLLocationCoordinate2D`，是因为后者不是
    /// `Equatable` —— 而这一层的全部价值就在于状态可以逐字比较。
    struct Coordinate: Equatable {

        var latitude: Double
        var longitude: Double

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        init(_ coordinate: CLLocationCoordinate2D) {
            self.latitude = coordinate.latitude
            self.longitude = coordinate.longitude
        }

        var clLocation: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        /// 两个坐标之间的大圆距离（米）。
        static func distance(_ a: Coordinate, _ b: Coordinate) -> CLLocationDistance {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
    }

    // MARK: - 证据

    /// 链路探针的结论：**改写有没有上路**。
    ///
    /// 这是与「回读到什么位置」**相互独立**的一条证据。
    /// 上一代只用回读定位一条判据回答两个不同的问题，这是它最深的一个坑。
    enum LinkEvidence: Equatable {

        /// 还没探到（探针未启用、代理没跑起来、请求超时）。
        /// **不轻易判死** —— 下一轮再探。
        case unknown

        /// 经代理发出的探测请求被改写回显 → 链路是通的。
        case alive

        /// 代理层实测到 TLS 握手失败 → 改写不可能上路。
        ///
        /// 这条证据**只能来自实测**，不能来自版本号推断：
        /// iOS 27 的 beta 1~5 是可用区间，写成「27 就拦截」会误伤它们。
        case tlsRejected
    }

    /// 一次探测回读到的结果。
    enum ProbeOutcome: Equatable {
        case located(Coordinate)
        /// `authorizationStatus` 返回 `.denied`。
        /// **注意**：系统总开关关着时全机所有 App 都会返回这个，见 `.servicesEnabled` 事件。
        case denied
        case restricted
        /// 暂时解算不出来（室内 / 地下车库 / 刚进隧道）。
        case unavailable
    }

    // MARK: - 事件

    enum Event: Equatable {

        /// 开始（或重新开始）一轮校验。
        ///
        /// - Parameter coldStart: 是否是**应用冷启动后**的第一轮。
        ///   设备刚重启完时 `locationd` 自己也在初始化，那几秒里拿到的
        ///   `.denied` 是冤枉的，不能拿来结案。
        case started(target: Coordinate, coldStart: Bool)

        /// 续开一轮校验（回前台自动重校验等**非用户发起**的重启）。
        ///
        /// 与 `.started` 的唯一区别：**探测预算（`probesUsed`）不清零**。
        ///
        /// 为什么要区分：2026-10-13 用户实测抓到「校验一直停在验证中」——
        /// 用户进出一次软件，回前台自动重校验就把预算清零一次，只要探测
        /// 结果暂时对不上（iOS 26 的系统缓存尤其如此），状态机就永远走不到
        /// 终态，循环打转。续开保留预算，「有限时间内必出结论」这条承诺
        /// 才不被应用切换打断。目标点变了则照旧清零（旧预算对新点无意义）。
        case resumed(target: Coordinate, coldStart: Bool)

        /// 一次回读的结果。
        case probe(ProbeOutcome)

        /// 系统「定位服务」总开关的状态。
        case servicesEnabled(Bool)

        /// 链路探针的结果。
        case link(LinkEvidence)

        /// 改写层证据（2026-10-13 新增）：改写层**真的把目标坐标写进了
        /// 定位响应**。内置代理来自 Go 日志流水，第三方模式来自脚本诊断回读，
        /// 由 `RewriteLedger` 统一记账、`SpoofEffectVerifier` 只在本轮
        /// 开始后出现**新账**时才发这个事件。
        ///
        /// 为什么它能翻案：回读定位问的是「系统采用了没有」，而 iOS 26 的
        /// `locationd` 缓存可以让答案长期停在旧位置 —— 定位明明已经改了，
        /// 回读永远拿旧的，校验被冤成「系统未刷新」。改写证据问的是
        /// 「坐标喂出去没有」，这一步在改写层内部完成，不受系统缓存影响。
        case rewriteObserved

        /// 用户关掉了虚拟定位。
        case reset
    }

    // MARK: - 配置

    struct Config: Equatable {

        /// 判定为「同一个地方」的距离阈值（米）。
        ///
        /// 改写是逐字节替换经纬度，理论上回读值应当和目标点几乎完全一致。
        /// 留 80 米是给两件事：移动模拟打开时的抖动半径（最大 20 米），
        /// 以及系统对精度字段的取整。真实位置与选点差着几百米起步，
        /// 这个阈值不会把「没生效」误判成「生效」。
        var matchThreshold: CLLocationDistance = 80

        /// 一轮校验最多真正探测几次。
        var maxProbes: Int = 10

        /// 「总开关开着却读不到定位」要连续命中几次才结案。
        ///
        /// 一次就结案是上一代最大的坑：用户在系统设置里操作时，总开关必然有
        /// 关着的几秒，那一枪命中就判「没有定位权限」，而且**永不改口**。
        var deniedTolerance: Int = 2

        /// 冷启动后，前几次探测里拿到的 `.denied` 不结案。
        var coldStartWindow: Int = 2

        /// 链路为活、但回读连续多少轮仍未命中，才判「系统没刷新」。
        ///
        /// 给一段观察期是必要的：改写刚上路到系统采用新位置之间，
        /// 隔着一次重新解算。急着宣布「系统没刷新」会让用户白跑一趟设置。
        var linkObservationRounds: Int = 3

        static let standard = Config()
    }

    // MARK: - 状态

    struct State: Equatable {

        /// 对外展示的结论。UI 只读这一个字段。
        var publicState: SpoofState = .idle

        var target: Coordinate?

        /// 已经真正探测过系统几次。
        ///
        /// **暂停期间不增长** —— 否则用户去重启设备（分钟级）时，
        /// 10 次会在半分钟里烧光，等他回来时窗口早关了。
        var probesUsed: Int = 0

        /// 「总开关开着 + `.denied`」连续命中的次数。
        var deniedStreak: Int = 0

        /// 冷启动保护窗口还剩几次探测。
        var coldStartRemaining: Int = 0

        var linkEvidence: LinkEvidence = .unknown

        /// 系统「定位服务」总开关当前是否开着。默认按开着算。
        var servicesEnabled: Bool = true

        var verifiedAt: Date?

        /// 本轮是否观察到**改写层证据**（`.rewriteObserved`）。
        ///
        /// 与「回读命中」独立：回读命中说明系统采用了新位置（干净生效）；
        /// 只有改写证据说明坐标已下发、系统缓存还没翻篇（生效但缓存未刷新）。
        /// UI 用这对组合决定要不要附「重启设备可立即刷新」的提示。
        var sawRewrite: Bool = false

        /// 本轮回读是否命中过目标点（R1 的副作用记录）。
        var sawProbeMatch: Bool = false

        /// 生效但只凭改写证据（回读从未命中）——iOS 26 缓存未刷新的典型形态。
        var effectiveWithStaleCache: Bool {
            sawRewrite && !sawProbeMatch
        }

        /// 是否还接收探测事件。
        ///
        /// 暂停态（`systemServicesOff`）仍然接收 —— 用户把开关拨回来，
        /// 下一枪就该继续判。终态（已生效 / 非暂态未生效）不再接收。
        var acceptsProbes: Bool {
            guard target != nil else { return false }
            switch publicState {
            case .verifying:
                return true
            case .ineffective(let reason):
                return reason.isTransient
            case .idle, .effective:
                return false
            }
        }

        /// 是否已经有结论、驱动层可以停下来了。
        var isTerminal: Bool {
            switch publicState {
            case .effective:
                return true
            case .ineffective(let reason):
                return !reason.isTransient
            case .idle, .verifying:
                return false
            }
        }
    }

    // MARK: - 判定

    /// 一步状态迁移。**这个函数就是全部规则。**
    ///
    /// 规则编号与 `docs/05-P2校验状态机方案.md` 一一对应：
    ///
    /// - **R1** 命中即生效
    /// - **R2** 总开关关着：暂停，不结案（`systemServicesOff` 是暂态）
    /// - **R3** `.denied` 要「总开关开着 + 连中两次 + 不在冷启动窗口」才结案
    /// - **R4** `.restricted` 直接结案
    /// - **R5** `.unavailable` 只是没解出来，继续
    /// - **R6** 链路证据与结果证据交叉，分辨「代理没接上」与「系统没刷新」
    /// - **R9** 到达探测上限必须给结论，永不永久停在 `verifying`
    ///
    /// - Parameter now: 判定为生效时记的时间戳。做成参数是为了让整条链路
    ///   在单测里**完全确定** —— 直接调 `Date()` 就没法断言了。
    static func reduce(
        _ state: State,
        _ event: Event,
        now: Date = Date(),
        config: Config = .standard
    ) -> State {
        var s = state

        switch event {

        // MARK: - R0 · 复位

        case .reset:
            return State()

        // MARK: - 开始 / 重开一轮

        case .started(let target, let coldStart):
            s.target = target
            s.publicState = .verifying
            s.probesUsed = 0
            s.deniedStreak = 0
            s.coldStartRemaining = coldStart ? config.coldStartWindow : 0
            // 证据痕迹跟着新目标重置：改写账本本身是全局客观事实，
            // 但「本轮的账」必须从零看起，旧账由校验器的基线比对挡住。
            s.sawRewrite = false
            s.sawProbeMatch = false
            // 链路证据重新探，不继承上一轮 —— 用户可能刚把代理修好。
            s.linkEvidence = .unknown
            s.verifiedAt = nil
            return s

        // MARK: - 续开一轮（预算保留）

        case .resumed(let target, let coldStart):
            // 目标点变了：旧预算对新的点毫无意义，照 .started 全部清零。
            // 必须在赋值**之前**比较 —— 先赋值再比就永远相等了。
            let targetChanged = (s.target != target)
            s.target = target
            s.publicState = .verifying
            if targetChanged {
                s.probesUsed = 0
                s.deniedStreak = 0
                s.sawRewrite = false
                s.sawProbeMatch = false
            }
            s.coldStartRemaining = coldStart ? config.coldStartWindow : 0
            // 链路证据照旧重新探 —— 用户可能刚把代理修好。
            s.linkEvidence = .unknown
            s.verifiedAt = nil
            return s

        // MARK: - R2 · 总开关

        case .servicesEnabled(let enabled):
            s.servicesEnabled = enabled

            // 开关回来了：解除暂停，重新开始计数。
            // 之前那些 `.denied` 是"用户正在操作"造成的，一笔勾销。
            if enabled, case .ineffective(.systemServicesOff) = s.publicState {
                s.publicState = .verifying
                s.deniedStreak = 0
            }
            return s

        // MARK: - R6 · 链路证据

        case .link(let evidence):
            s.linkEvidence = evidence

            // TLS 被拒 = 改写不可能上路，不必再等回读，直接给结论。
            if evidence == .tlsRejected, s.acceptsProbes {
                s.publicState = .ineffective(.proxyUnreachable)
            }
            return s

        // MARK: - R7 · 改写层证据

        case .rewriteObserved:
            guard s.acceptsProbes else { return s }
            s.sawRewrite = true
            // 坐标已经喂进系统 = 事实上的生效。回读拿不到新位置是
            // 系统缓存的事（iOS 26 尤甚），不再让校验为它无限打转。
            // 已生效（R1 先到）时这里只是补一条痕迹，不动终态。
            if !s.isTerminal {
                s.publicState = .effective
                s.verifiedAt = now
            }
            return s

        // MARK: - R1 / R3 / R4 / R5 / R6 / R9 · 一次探测

        case .probe(let outcome):
            guard s.acceptsProbes else { return s }

            switch outcome {

            // R1 · 回读到位置
            case .located(let coordinate):
                s.deniedStreak = 0
                s.probesUsed += 1
                if s.coldStartRemaining > 0 { s.coldStartRemaining -= 1 }

                if isEffective(probe: coordinate, target: s.target,
                               threshold: config.matchThreshold) {
                    s.sawProbeMatch = true
                    s.publicState = .effective
                    s.verifiedAt = now
                    return s
                }

                // 没命中：只有链路证据能分辨是哪一种失败
                settle(&s, verdict: failureForUnmatchedProbe(s, config: config), now: now)

            // R3 · 被拒绝
            case .denied:
                // 总开关关着 → 这是「用户正在操作」（引导词教的），
                // 不是「本应用没有授权」。**暂态，不结案。**
                if !s.servicesEnabled {
                    s.publicState = .ineffective(.systemServicesOff)
                    s.deniedStreak = 0
                    return s
                }

                s.probesUsed += 1
                s.deniedStreak += 1

                // 判定要用**这次探测开始时**的窗口状态。
                //
                // 窗口保护的是「前 N 次探测」，第 N 次本身也在保护范围内。
                // 若先递减再判定，第 N 次会因为窗口刚好归零而被结案 ——
                // 保护窗口实际只剩 N-1 次。（这条是单测抓出来的。）
                let insideColdStart = s.coldStartRemaining > 0
                if s.coldStartRemaining > 0 { s.coldStartRemaining -= 1 }

                if !insideColdStart, s.deniedStreak >= config.deniedTolerance {
                    settle(&s, verdict: .ineffective(.permissionDenied), now: now)
                } else if s.probesUsed >= config.maxProbes {
                    settle(&s, verdict: .ineffective(.systemNotResolved), now: now)
                }

            // R4 · 被策略限制
            case .restricted:
                s.publicState = .ineffective(.restricted)

            // R5 · 暂时解不出来
            case .unavailable:
                s.deniedStreak = 0
                s.probesUsed += 1
                if s.coldStartRemaining > 0 { s.coldStartRemaining -= 1 }
                if s.probesUsed >= config.maxProbes {
                    settle(&s, verdict: .ineffective(.systemNotResolved), now: now)
                }
            }
            return s
        }
    }

    /// 结论收口：**「系统未刷新」的冤案在这里翻案**。
    ///
    /// 到达探测上限、链路活着却始终回读不到目标点 —— 旧版直接判
    /// 「系统未刷新」。但如果本轮已经拿到改写层证据（坐标确实喂出去了），
    /// 这就是 iOS 26 缓存不刷新的典型形态，定位其实已经生效，
    /// 判成失败只会让用户去重启设备或者干着急。
    private static func settle(_ s: inout State, verdict: SpoofState, now: Date) {
        if case .ineffective(.systemNotResolved) = verdict, s.sawRewrite {
            s.publicState = .effective
            s.verifiedAt = now
            return
        }
        s.publicState = verdict
    }

    /// 回读到位置、但**不是**目标点时的结论。
    ///
    /// 这一步就是「两个问题、两条证据」的落点：
    /// 链路活 → 改写上去了，是系统没刷新；链路死 → 改写压根没上路。
    private static func failureForUnmatchedProbe(
        _ state: State,
        config: Config
    ) -> SpoofState {

        // 观察期未满：先不下结论，再探几轮看看。
        guard state.probesUsed >= config.linkObservationRounds else {
            return .verifying
        }

        switch state.linkEvidence {
        case .tlsRejected:
            return .ineffective(.proxyUnreachable)

        case .alive:
            return .ineffective(.systemNotResolved)

        case .unknown:
            // 链路还没探到。宁可等到上限再保守地报「系统没刷新」，
            // 也不要在这里武断地报「代理未接上」—— 方向错了用户会白查一通。
            return state.probesUsed >= config.maxProbes
                ? .ineffective(.systemNotResolved)
                : .verifying
        }
    }

    /// 纯判定：回读坐标与目标点算不算同一个地方。
    static func isEffective(
        probe: Coordinate,
        target: Coordinate?,
        threshold: CLLocationDistance = Config.standard.matchThreshold
    ) -> Bool {
        guard let target else { return false }
        return Coordinate.distance(probe, target) <= threshold
    }
}
