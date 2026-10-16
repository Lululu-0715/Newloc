import XCTest
@testable import Newloc

/// 校验判定的规则表。
///
/// 这一层之所以值得 30 多条测试，是因为上一代的同类逻辑写成了一段 90 行的
/// async 循环 —— 规则埋在控制流里，单测只能测「整轮跑完的最终状态」，
/// 中间怎么迁移完全测不到。而它最严重的那几个 bug（一直报「权限未开」、
/// 回前台不重新校验）恰好都出在中间迁移上。
///
/// 拆成纯函数之后，每条规则都能用几毫秒跑完，包括「用户在系统设置里
/// 把总开关关了 5 秒再打开」这种真机现象。
final class SpoofEffectJudgeTests: XCTestCase {

    // MARK: - 夹具

    private typealias Judge = SpoofJudge
    private typealias State = SpoofJudge.State
    private typealias Event = SpoofJudge.Event
    private typealias Outcome = SpoofJudge.ProbeOutcome
    private typealias Evidence = SpoofJudge.LinkEvidence
    private typealias Reason = IneffectiveReason

    /// 目标点：北京。
    private let target = Judge.Coordinate(latitude: 39.904200, longitude: 116.407400)

    /// 距目标约 33 米 —— 在 80 米阈值内。
    private let nearby = Judge.Coordinate(latitude: 39.904500, longitude: 116.407400)

    /// 距目标约 89 米 —— 刚出阈值。
    private let justOutside = Judge.Coordinate(latitude: 39.904200 + 0.0008, longitude: 116.407400)

    /// 距目标十几公里 —— 典型的「还是真实位置」。
    private let faraway = Judge.Coordinate(latitude: 40.000000, longitude: 116.500000)

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// 把一串事件喂进去，返回终态。
    private func run(
        _ events: [Event],
        from initial: State = State(),
        config: Judge.Config = .standard
    ) -> State {
        events.reduce(initial) { Judge.reduce($0, $1, now: fixedNow, config: config) }
    }

    /// 开始一轮校验（非冷启动）。
    private var start: Event { .started(target: target, coldStart: false) }

    /// 开始一轮校验（模拟设备刚重启）。
    private var coldStart: Event { .started(target: target, coldStart: true) }

    private func isPermissionDenied(_ state: State) -> Bool {
        state.publicState == .ineffective(.permissionDenied)
    }

    // MARK: - R1 · 命中即生效

    func testProbeOnTargetBecomesEffective() {
        let state = run([start, .probe(.located(target))])
        XCTAssertEqual(state.publicState, .effective)
        XCTAssertEqual(state.verifiedAt, fixedNow)
    }

    func testProbeWithinThresholdBecomesEffective() {
        // 改写是逐字节替换，偏差本来就接近 0；33 米是余量范围。
        let state = run([start, .probe(.located(nearby))])
        XCTAssertEqual(state.publicState, .effective)
    }

    func testProbeJustOutsideThresholdDoesNotBecomeEffective() {
        let state = run([start, .probe(.located(justOutside))])
        XCTAssertNotEqual(state.publicState, .effective)
    }

    func testThresholdBoundaryIsInclusive() {
        // 距离判定是 `<=`：正好落在阈值上算命中。
        XCTAssertTrue(Judge.isEffective(probe: nearby, target: target, threshold: 33.4))
        XCTAssertFalse(Judge.isEffective(probe: nearby, target: target, threshold: 33.3))
    }

    func testEffectiveIsTerminalAndIgnoresLaterProbes() {
        let state = run([
            start,
            .probe(.located(target)),
            .probe(.located(faraway)),
            .probe(.denied),
        ])
        XCTAssertEqual(state.publicState, .effective)
        XCTAssertTrue(state.isTerminal)
    }

    func testEffectiveTimestampIsNotOverwritten() {
        // 已经生效之后再来一枪命中，不应该刷新时间戳（否则界面上的
        // 「校验通过 12:04」会不停跳动）。
        let later = fixedNow.addingTimeInterval(600)
        var state = run([start, .probe(.located(target))])
        state = Judge.reduce(state, .probe(.located(target)), now: later)
        XCTAssertEqual(state.verifiedAt, fixedNow)
    }

    // MARK: - R2 · 总开关关着：暂停，不结案

    func testDeniedWithServicesOffPausesInsteadOfConcluding() {
        let state = run([
            start,
            .servicesEnabled(false),
            .probe(.denied),
        ])
        XCTAssertEqual(state.publicState, .ineffective(.systemServicesOff))
    }

    func testSystemServicesOffIsTransient() {
        XCTAssertTrue(Reason.systemServicesOff.isTransient)
    }

    func testOtherReasonsAreNotTransient() {
        XCTAssertFalse(Reason.permissionDenied.isTransient)
        XCTAssertFalse(Reason.restricted.isTransient)
        XCTAssertFalse(Reason.proxyUnreachable.isTransient)
        XCTAssertFalse(Reason.systemNotResolved.isTransient)
    }

    func testServicesDisabledDoesNotConsumeProbes() {
        // 这是上一代误报的核心：用户按引导去关开关的那几秒，
        // 每一次 `.denied` 都被当成一次「探测失败」计数。
        let state = run([
            start,
            .servicesEnabled(false),
            .probe(.denied),
            .probe(.denied),
            .probe(.denied),
            .probe(.denied),
            .probe(.denied),
        ])
        XCTAssertEqual(state.probesUsed, 0)
        XCTAssertEqual(state.deniedStreak, 0)
    }

    func testServicesBackOnResumesVerification() {
        let state = run([
            start,
            .servicesEnabled(false),
            .probe(.denied),
            .servicesEnabled(true),
        ])
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testServicesBackOnClearsDeniedStreak() {
        // 关开关期间攒下的 `.denied` 一笔勾销 —— 那些是「用户正在操作」，
        // 不是「应用没有权限」。
        let state = run([
            start,
            .servicesEnabled(true),
            .probe(.denied),
            .servicesEnabled(false),
            .probe(.denied),
            .servicesEnabled(true),
        ])
        XCTAssertEqual(state.deniedStreak, 0)
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testServicesOffNeverReportsPermissionDenied() {
        var state = run([start, .servicesEnabled(false)])
        for _ in 0..<10 {
            state = Judge.reduce(state, .probe(.denied), now: fixedNow)
            XCTAssertFalse(isPermissionDenied(state))
        }
    }

    // MARK: - R3 · `.denied` 的结案条件

    func testDeniedTwiceWithServicesOnConcludesPermissionDenied() {
        let state = run([
            start,
            .servicesEnabled(true),
            .probe(.denied),
            .probe(.denied),
        ])
        XCTAssertEqual(state.publicState, .ineffective(.permissionDenied))
    }

    func testSingleDeniedDoesNotConclude() {
        // 一次就结案是上一代最大的坑：那一枪命中就判「没有定位权限」，
        // 而且永不改口。
        let state = run([start, .probe(.denied)])
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testColdStartWindowSuppressesDeniedConclusion() {
        // 设备刚重启完，`locationd` 自己也在初始化，这时候的 `.denied` 是冤枉的。
        var state = run([coldStart, .servicesEnabled(true)])
        for _ in 0..<SpoofJudge.Config.standard.coldStartWindow {
            state = Judge.reduce(state, .probe(.denied), now: fixedNow)
            XCTAssertFalse(isPermissionDenied(state), "冷启动窗口内不得结案")
        }
    }

    func testDeniedConcludesAfterColdStartWindow() {
        var state = run([coldStart, .servicesEnabled(true)])
        // 冷启动窗口 2 次，之后再连中 2 次 → 结案。
        for _ in 0..<SpoofJudge.Config.standard.coldStartWindow {
            state = Judge.reduce(state, .probe(.denied), now: fixedNow)
        }
        state = Judge.reduce(state, .probe(.denied), now: fixedNow)
        state = Judge.reduce(state, .probe(.denied), now: fixedNow)
        XCTAssertTrue(isPermissionDenied(state))
    }

    func testNonColdStartHasNoGraceWindow() {
        let state = run([start, .servicesEnabled(true), .probe(.denied), .probe(.denied)])
        XCTAssertTrue(isPermissionDenied(state))
    }

    func testSuccessResetsDeniedStreak() {
        // 中间成功过一次，`.denied` 的连续计数必须归零 ——
        // 否则「一拍一拍的失败」会攒成一次误判。
        let state = run([
            start,
            .servicesEnabled(true),
            .probe(.denied),
            .probe(.located(target)),
        ])
        XCTAssertEqual(state.deniedStreak, 0)
        XCTAssertEqual(state.publicState, .effective)
    }

    // MARK: - R4 · 被策略限制

    func testRestrictedConcludesImmediately() {
        let state = run([start, .probe(.restricted)])
        XCTAssertEqual(state.publicState, .ineffective(.restricted))
    }

    func testRestrictedConcludesEvenInsideColdStartWindow() {
        // 被家长控制 / MDM 限制不是暂态，自己不会好，不必等窗口。
        let state = run([coldStart, .probe(.restricted)])
        XCTAssertEqual(state.publicState, .ineffective(.restricted))
    }

    // MARK: - R5 · 暂时解不出来

    func testUnavailableKeepsVerifying() {
        let state = run([start, .probe(.unavailable)])
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testUnavailableResetsDeniedStreak() {
        let state = run([
            start,
            .servicesEnabled(true),
            .probe(.denied),
            .probe(.unavailable),
        ])
        XCTAssertEqual(state.deniedStreak, 0)
    }

    // MARK: - R6 · 两个问题、两条证据

    func testLinkAliveWithUnmatchedProbeConcludesSystemNotResolved() {
        let state = run([
            start,
            .link(.alive),
            .probe(.located(faraway)),   // 1
            .probe(.located(faraway)),   // 2
            .probe(.located(faraway)),   // 3 —— 观察期满
        ])
        XCTAssertEqual(state.publicState, .ineffective(.systemNotResolved))
    }

    func testLinkTLSRejectedConcludesProxyUnreachable() {
        let state = run([
            start,
            .link(.tlsRejected),
            .probe(.located(faraway)),
            .probe(.located(faraway)),
            .probe(.located(faraway)),
        ])
        XCTAssertEqual(state.publicState, .ineffective(.proxyUnreachable))
    }

    func testLinkTLSRejectedConcludesWithoutWaitingForProbe() {
        // 证书被拒 = 改写不可能上路，不必再等回读。
        let state = run([start, .link(.tlsRejected)])
        XCTAssertEqual(state.publicState, .ineffective(.proxyUnreachable))
    }

    func testLinkAliveDoesNotConcludeBeforeObservationPeriod() {
        // 改写刚上路到系统采用新位置之间隔着一次重新解算，
        // 急着宣布「系统没刷新」会让用户白跑一趟设置。
        let state = run([
            start,
            .link(.alive),
            .probe(.located(faraway)),
        ])
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testLinkUnknownKeepsVerifying() {
        let state = run([
            start,
            .probe(.located(faraway)),
            .probe(.located(faraway)),
            .probe(.located(faraway)),
        ])
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testLinkUnknownEventuallyConcludesSystemNotResolved() {
        // 保守兜底：链路一直探不到，到了上限宁可说「系统没刷新」，
        // 也不要武断地说「代理未接上」—— 方向错了用户会白查一通。
        var events: [Event] = [start]
        for _ in 0..<Judge.Config.standard.maxProbes {
            events.append(.probe(.located(faraway)))
        }
        let state = run(events)
        XCTAssertEqual(state.publicState, .ineffective(.systemNotResolved))
    }

    func testLinkEvidenceCanArriveAfterProbes() {
        // 链路证据晚到也要能改结论：先探了几轮回读，之后才探到链路。
        let state = run([
            start,
            .probe(.located(faraway)),
            .probe(.located(faraway)),
            .probe(.located(faraway)),
            .link(.tlsRejected),
        ])
        XCTAssertEqual(state.publicState, .ineffective(.proxyUnreachable))
    }

    func testLinkAliveAndTLSRejectedAreDistinguished() {
        // 同样是「回读到旧位置」，两条链路证据给出**不同**的结论 ——
        // 这正是这一版最大的改动。
        let resolved = run([
            start, .link(.alive),
            .probe(.located(faraway)), .probe(.located(faraway)), .probe(.located(faraway)),
        ])
        let unreachable = run([
            start, .link(.tlsRejected),
            .probe(.located(faraway)), .probe(.located(faraway)), .probe(.located(faraway)),
        ])
        XCTAssertEqual(resolved.publicState, .ineffective(.systemNotResolved))
        XCTAssertEqual(unreachable.publicState, .ineffective(.proxyUnreachable))
    }

    // MARK: - R9 · 必须收口

    func testReachesConclusionAtProbeLimit() {
        var events: [Event] = [start, .link(.alive)]
        for _ in 0..<Judge.Config.standard.maxProbes {
            events.append(.probe(.located(faraway)))
        }
        let state = run(events)
        XCTAssertTrue(state.isTerminal)
    }

    func testUnavailableProbesAlsoReachConclusion() {
        var events: [Event] = [start]
        for _ in 0..<Judge.Config.standard.maxProbes {
            events.append(.probe(.unavailable))
        }
        let state = run(events)
        XCTAssertTrue(state.isTerminal)
    }

    func testDeniedProbesAlsoReachConclusion() {
        var events: [Event] = [start, .servicesEnabled(true)]
        for _ in 0..<Judge.Config.standard.maxProbes {
            events.append(.probe(.denied))
        }
        let state = run(events)
        XCTAssertTrue(state.isTerminal)
    }

    func testNeverStaysVerifyingForever() {
        // 钉子：把三种失败结果任意混合，到达上限后必须给出结论，
        // 不允许永远停在「验证中」。
        let outcomes: [Outcome] = [.located(faraway), .unavailable, .denied]
        for offset in 0..<outcomes.count {
            var events: [Event] = [start, .servicesEnabled(true)]
            for index in 0..<(Judge.Config.standard.maxProbes * 2) {
                events.append(.probe(outcomes[(index + offset) % outcomes.count]))
            }
            let state = run(events)
            XCTAssertTrue(state.isTerminal, "第 \(offset) 组序列没有收口")
        }
    }

    func testProbeCountStopsAtLimit() {
        var events: [Event] = [start, .servicesEnabled(true)]
        for _ in 0..<(Judge.Config.standard.maxProbes * 3) {
            events.append(.probe(.located(faraway)))
        }
        let state = run(events)
        XCTAssertLessThanOrEqual(state.probesUsed, Judge.Config.standard.maxProbes)
    }

    // MARK: - R7 · 改写层证据翻案（2026-10-13 iOS 26 缓存死穴）

    func testRewriteEvidenceAloneConcludesEffective() {
        // 回读从未命中（iOS 26 缓存），但改写账上有本轮记录 → 直接生效。
        let state = run([start, .rewriteObserved])
        XCTAssertEqual(state.publicState, .effective)
        XCTAssertEqual(state.verifiedAt, fixedNow)
        XCTAssertTrue(state.sawRewrite)
        XCTAssertFalse(state.sawProbeMatch)
        XCTAssertTrue(state.effectiveWithStaleCache)
    }

    func testRewriteEvidenceDoesNotDisturbExistingVerdict() {
        // 先干净生效（R1），改写证据后到 —— 终态不被打扰，且不误标缓存提示。
        let state = run([start, .probe(.located(nearby)), .rewriteObserved])
        XCTAssertEqual(state.publicState, .effective)
        XCTAssertTrue(state.sawProbeMatch)
        XCTAssertFalse(state.effectiveWithStaleCache)
    }

    func testRewriteEvidenceOverrulesSystemNotResolved() {
        // 钉子场景：链路活着、回读一直拿旧位置、到上限 —— 旧版判
        // 「系统未刷新」，有改写证据时翻案成「已生效」。
        var events: [Event] = [start, .link(.alive), .rewriteObserved]
        for _ in 0..<Judge.Config.standard.maxProbes {
            events.append(.probe(.located(faraway)))
        }
        let state = run(events)
        XCTAssertEqual(state.publicState, .effective)
        XCTAssertTrue(state.effectiveWithStaleCache)
    }

    func testWithoutRewriteEvidenceVerdictStaysOldWay() {
        // 没有改写证据时老路照走：不翻案，否则「没生效」会被误报成「已生效」。
        var events: [Event] = [start, .link(.alive)]
        for _ in 0..<Judge.Config.standard.maxProbes {
            events.append(.probe(.located(faraway)))
        }
        let state = run(events)
        XCTAssertEqual(state.publicState, .ineffective(.systemNotResolved))
        XCTAssertFalse(state.sawRewrite)
    }

    func testRewriteEvidenceIgnoredWhenNotAcceptingProbes() {
        // reset 后账本来了一条迟到记录 —— 不应把 idle 拉成生效。
        let state = run([start, .reset, .rewriteObserved])
        XCTAssertEqual(state.publicState, .idle)
    }

    func testNewTargetClearsRewriteEvidence() {
        // 换目标：旧目标的改写账不能给新目标背书（resumed 清零路径）。
        let newTarget = Judge.Coordinate(latitude: 31.230400, longitude: 121.473700)
        let state = run([
            start, .rewriteObserved,
            .resumed(target: newTarget, coldStart: false),
        ])
        XCTAssertFalse(state.sawRewrite)
        XCTAssertEqual(state.publicState, .verifying)
    }

    // MARK: - started / reset

    func testStartedResetsCounters() {
        let state = run([
            start,
            .servicesEnabled(true),
            .probe(.denied),
            start,
        ])
        XCTAssertEqual(state.publicState, .verifying)
        XCTAssertEqual(state.probesUsed, 0)
        XCTAssertEqual(state.deniedStreak, 0)
        XCTAssertNil(state.verifiedAt)
    }

    func testStartedResetsLinkEvidence() {
        // 用户可能刚把代理修好，重新开始时必须重新探链路。
        let state = run([start, .link(.tlsRejected), start])
        XCTAssertEqual(state.linkEvidence, .unknown)
    }

    func testStartedOnNewTargetSwitchesTarget() {
        let other = Judge.Coordinate(latitude: 31.230400, longitude: 121.473700)
        var state = run([start, .probe(.located(target))])
        XCTAssertEqual(state.publicState, .effective)

        state = Judge.reduce(state, .started(target: other, coldStart: false), now: fixedNow)
        XCTAssertEqual(state.target, other)
        XCTAssertEqual(state.publicState, .verifying)
    }

    func testResetReturnsToIdleAndClearsTarget() {
        let state = run([start, .probe(.located(target)), .reset])
        XCTAssertEqual(state.publicState, .idle)
        XCTAssertNil(state.target)
    }

    func testProbesAreIgnoredAfterReset() {
        // reset 之后还飘进来一个探测结果（循环正在收尾），不能把状态又推回去。
        let state = run([start, .reset, .probe(.located(target))])
        XCTAssertEqual(state.publicState, .idle)
    }

    func testIdleStateRejectsProbes() {
        let state = run([.probe(.located(target))])
        XCTAssertEqual(state.publicState, .idle)
        XCTAssertEqual(state.probesUsed, 0)
    }

    func testTerminalStateRejectsFurtherProbes() {
        let state = run([
            start,
            .probe(.restricted),
            .probe(.located(target)),
        ])
        XCTAssertEqual(state.publicState, .ineffective(.restricted))
    }

    // MARK: - resumed（续开，预算保留）

    func testResumedKeepsProbeBudget() {
        // 这是「一直验证中」bug 的直接回归：回前台续开时预算不许清零，
        // 否则用户每进出一次软件，状态机离终态反而更远。
        var state = run([start])
        for _ in 0..<4 {
            state = Judge.reduce(state, .probe(.unavailable), now: fixedNow)
        }
        XCTAssertEqual(state.probesUsed, 4)

        state = Judge.reduce(state, .resumed(target: target, coldStart: false), now: fixedNow)
        XCTAssertEqual(state.publicState, .verifying)
        XCTAssertEqual(state.probesUsed, 4, "续开把探测预算清零了")
    }

    func testResumedConcludesWithinBudgetDespiteRestarts() {
        // 端到端场景：探测一直拿不到目标（iOS 26 缓存），中间穿插多次
        // 回前台续开 —— 10 次预算烧完必须给出结论，不能无限停在验证中。
        var state = run([start])
        for _ in 0..<20 {
            if state.isTerminal { break }
            state = Judge.reduce(state, .probe(.unavailable), now: fixedNow)
            if state.isTerminal { break }
            state = Judge.reduce(state, .resumed(target: target, coldStart: false), now: fixedNow)
        }
        XCTAssertEqual(state.publicState, .ineffective(.systemNotResolved))
    }

    func testResumedOnChangedTargetResetsBudget() {
        // 换了目标点：旧预算对新点毫无意义，照 .started 清零。
        let other = Judge.Coordinate(latitude: 31.230400, longitude: 121.473700)
        var state = run([start])
        for _ in 0..<4 {
            state = Judge.reduce(state, .probe(.unavailable), now: fixedNow)
        }
        XCTAssertEqual(state.probesUsed, 4)

        state = Judge.reduce(state, .resumed(target: other, coldStart: false), now: fixedNow)
        XCTAssertEqual(state.target, other)
        XCTAssertEqual(state.probesUsed, 0)
    }

    func testResumedResetsLinkEvidence() {
        let state = run([start, .link(.alive), .resumed(target: target, coldStart: false)])
        XCTAssertEqual(state.linkEvidence, .unknown)
    }

    // MARK: - 冷启动判定

    func testColdStartWindowCountsDown() {
        var state = run([coldStart])
        XCTAssertEqual(state.coldStartRemaining, Judge.Config.standard.coldStartWindow)
        state = Judge.reduce(state, .probe(.located(faraway)), now: fixedNow)
        XCTAssertEqual(state.coldStartRemaining, Judge.Config.standard.coldStartWindow - 1)
    }

    func testNonColdStartHasEmptyWindow() {
        let state = run([start])
        XCTAssertEqual(state.coldStartRemaining, 0)
    }

    // MARK: - 综合场景（钉子）

    func testServicesToggleDuringVerificationNeverReportsPermissionDenied() {
        // 这就是真机上那条路径：引导教用户去关一下总开关再打开。
        // 全程**不得**出现「未授予定位权限」，最终必须生效。
        var state = run([start])

        state = Judge.reduce(state, .servicesEnabled(false), now: fixedNow)
        for _ in 0..<5 {
            state = Judge.reduce(state, .probe(.denied), now: fixedNow)
            XCTAssertFalse(isPermissionDenied(state), "开关关着期间判成了无权限")
        }
        XCTAssertEqual(state.probesUsed, 0, "暂停期间消耗了探测次数")

        state = Judge.reduce(state, .servicesEnabled(true), now: fixedNow)
        XCTAssertEqual(state.publicState, .verifying)

        state = Judge.reduce(state, .probe(.located(target)), now: fixedNow)
        XCTAssertEqual(state.publicState, .effective)
    }

    func testHappyPathWithLinkEvidence() {
        let state = run([
            start,
            .servicesEnabled(true),
            .link(.alive),
            .probe(.located(faraway)),
            .probe(.located(target)),
        ])
        XCTAssertEqual(state.publicState, .effective)
        XCTAssertEqual(state.probesUsed, 2)
    }

    func testProxyUnreachableThenFixedAndSucceeds() {
        // 用户按提示查了证书，重新开始一轮之后成功。
        var state = run([start, .link(.tlsRejected)])
        XCTAssertEqual(state.publicState, .ineffective(.proxyUnreachable))

        state = Judge.reduce(state, .started(target: target, coldStart: false), now: fixedNow)
        state = Judge.reduce(state, .link(.alive), now: fixedNow)
        state = Judge.reduce(state, .probe(.located(target)), now: fixedNow)
        XCTAssertEqual(state.publicState, .effective)
    }

    // MARK: - 配置

    func testDefaultThresholdIsEightyMeters() {
        XCTAssertEqual(Judge.Config.standard.matchThreshold, 80)
    }

    func testIsEffectiveWithoutTargetIsFalse() {
        XCTAssertFalse(Judge.isEffective(probe: target, target: nil))
    }

    func testCoordinateDistanceIsSane() {
        let distance = Judge.Coordinate.distance(target, nearby)
        XCTAssertGreaterThan(distance, 25)
        XCTAssertLessThan(distance, 45)
    }

    func testCoordinateRoundTripsThroughCoreLocation() {
        let original = Judge.Coordinate(latitude: 39.9042, longitude: 116.4074)
        let roundTripped = Judge.Coordinate(original.clLocation)
        XCTAssertEqual(roundTripped, original)
    }
}
