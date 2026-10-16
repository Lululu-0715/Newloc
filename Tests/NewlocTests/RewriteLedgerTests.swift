import XCTest
@testable import Newloc

/// 改写证据账本的记账规则。
///
/// 账本是校验器「换证据源」的地基（2026-10-13）：内置代理日志与第三方
/// 脚本诊断都从这里过账。记错一笔，校验器就会把没生效的判成生效 ——
/// 所以解析规则和时间戳去重都必须有钉子。
final class RewriteLedgerTests: XCTestCase {

    private var ledger: RewriteLedger { RewriteLedger.shared }

    override func setUp() {
        super.setUp()
        ledger.clear()
    }

    override func tearDown() {
        ledger.clear()
        super.tearDown()
    }

    func testBuiltinRewriteLineIsRecorded() {
        // proxy.go 改写成功时的实际格式（proxy_logger 顺手核对）。
        ledger.observeBuiltinLogLine("12:03:04.567  WLOC 已改写 位置=6 WiFi=4 基站=0 跳过=0 输入=900 输出=912")
        XCTAssertEqual(ledger.rewriteCount, 1)
        XCTAssertNotNil(ledger.lastRewriteAt)
    }

    func testUnrelatedLinesAreIgnored() {
        ledger.observeBuiltinLogLine("12:03:04.567  CONNECT gs-loc-cn.apple.com → 中间人")
        ledger.observeBuiltinLogLine("12:03:05.001  收到代理验证请求")
        ledger.observeBuiltinLogLine("12:03:05.120  WLOC 改写跳过: 未找到可改写的 WLOC 载荷")
        XCTAssertEqual(ledger.rewriteCount, 0)
        XCTAssertNil(ledger.lastRewriteAt)
    }

    func testThirdPartyDiagIsRecordedOncePerTimestamp() {
        // probe 会把同一份诊断反复读回来 —— 同一个 ts 只能记一次账，
        // 否则校验器把「读了很多遍」当成「改写了很多次」。
        ledger.observeThirdPartyDiag(tsMilliseconds: 1_700_000_000_000)
        ledger.observeThirdPartyDiag(tsMilliseconds: 1_700_000_000_000)
        ledger.observeThirdPartyDiag(tsMilliseconds: 1_700_000_000_000)
        XCTAssertEqual(ledger.rewriteCount, 1)

        ledger.observeThirdPartyDiag(tsMilliseconds: 1_700_000_001_000)
        XCTAssertEqual(ledger.rewriteCount, 2)
    }

    func testZeroTimestampIsRejected() {
        // 缺 ts 字段的诊断（老版本脚本）宁可不记 —— 不可靠的证据不入账。
        ledger.observeThirdPartyDiag(tsMilliseconds: 0)
        XCTAssertEqual(ledger.rewriteCount, 0)
    }

    func testClearResetsEverything() {
        ledger.observeBuiltinLogLine("WLOC 已改写 位置=1 WiFi=0 基站=0 跳过=0 输入=1 输出=1")
        ledger.clear()
        XCTAssertEqual(ledger.rewriteCount, 0)
        XCTAssertNil(ledger.lastRewriteAt)
    }

    // MARK: 事件驱动（2026-10-13 提速）

    func testRecordPostsNotification() {
        // 校验器的「改写发生 → 立即结案」靠这条通知。丢了它，
        // 事件驱动通道就静默失效，只剩轮询兜底 —— 速度退回旧版。
        let expectation = expectation(forNotification: RewriteLedger.didRecordNotification,
                                      object: nil)
        ledger.observeBuiltinLogLine("WLOC 已改写 位置=1 WiFi=0 基站=0 跳过=0 输入=1 输出=1")
        wait(for: [expectation], timeout: 2)
    }

    func testDuplicateThirdPartyDiagDoesNotPostNotification() {
        // 同一份诊断被 probe 反复读回：不重复记账，也不该重复广播 ——
        // 否则判定层收多一发 .rewriteObserved（幂等无害，但证明去重失效）。
        var hits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: RewriteLedger.didRecordNotification, object: nil, queue: nil) { _ in
            hits += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        ledger.observeThirdPartyDiag(tsMilliseconds: 1_700_000_000_000)
        ledger.observeThirdPartyDiag(tsMilliseconds: 1_700_000_000_000)
        XCTAssertEqual(hits, 1)
    }
}
