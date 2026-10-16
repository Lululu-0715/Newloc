import XCTest

@testable import Newloc

/// `AsyncMutex`：跨越 `await` 的临界区互斥。
///
/// 这条用例守的是一个**实测抓到过**的回归：链路探针的验证 token 在 Go 侧是
/// 全局单例，两个并发探针会互相把 token 踩掉，于是链路明明通着却报「未生效」。
/// 闸门一旦失效，那个假阴性就会回来，而且只在「两个调用恰好重叠」时出现 ——
/// 靠手点是碰不到的，只能靠这里钉住。
final class AsyncMutexTests: XCTestCase {

    /// 并发计数：记录观察到的最大同时进入数。
    private actor ConcurrencyMeter {

        private var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    func testOnlyOneHolderAtATime() async {
        let mutex = AsyncMutex()
        let meter = ConcurrencyMeter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await mutex.acquire()
                    await meter.enter()
                    // 停在临界区里一小会儿，好让别的任务有机会挤进来。
                    try? await Task.sleep(nanoseconds: 500_000)
                    await meter.leave()
                    mutex.release()
                }
            }
        }

        let peak = await meter.peak
        XCTAssertEqual(peak, 1, "临界区里同时只能有一个任务，实测峰值是 \(peak)")
    }

    /// 串行不等于串行化整体 —— 32 个任务都得跑完，不能有谁被漏掉。
    func testEveryWaiterEventuallyRuns() async {
        let mutex = AsyncMutex()
        let meter = ConcurrencyMeter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await mutex.acquire()
                    await meter.enter()
                    await meter.leave()
                    mutex.release()
                }
            }
        }

        // 没有「跑完还剩一个卡在临界区」——若 release 漏掉了某个等待者，
        // 它会永远挂在那儿，测试会超时。
        let peak = await meter.peak
        XCTAssertEqual(peak, 1)
    }

    /// 没有竞争时不该有任何额外延迟（闸门不能变成瓶颈）。
    func testUncontendedAcquireIsImmediate() async {
        let mutex = AsyncMutex()

        let start = Date()
        for _ in 0..<100 {
            await mutex.acquire()
            mutex.release()
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "无竞争路径不该有可观测开销，实测 \(elapsed)s")
    }
}
