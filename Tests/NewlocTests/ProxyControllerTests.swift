import CoreLocation
import XCTest

@testable import Newloc

/// `ProxyController` 的状态机。
///
/// **为什么这些用例跑得动**：真实的 `CoreBridge` 会真的 bind 8888、真的起一个
/// HTTP 服务 —— 在单测里既慢又互相干扰（端口只有一个）。换成 `FakeProxyCore`
/// 之后，「端口被占」「证书拿不到」「核心拒绝启动」这些**只有真机上偶发**的
/// 分支，在毫秒内就能穷举。
@MainActor
final class ProxyControllerTests: XCTestCase {

    private let beijing = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
    private let shanghai = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)

    // MARK: - 组装

    private func makeDefaults() -> UserDefaults {
        // 每个用例一份独立命名空间，避免互相污染（也避免污染真实偏好）。
        UserDefaults(suiteName: "test.proxy.\(UUID().uuidString)")!
    }

    private func makeController(
        core: FakeProxyCore,
        authority: CertificateProviding = FakeAuthority(),
        defaults: UserDefaults
    ) -> ProxyController {
        ProxyController(authority: authority, core: core, defaults: defaults)
    }

    // MARK: - 启动

    func testStartsAndEntersRunning() throws {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        XCTAssertEqual(controller.status, .stopped)

        try controller.ensureRunning(at: beijing)

        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(core.startCount, 1)
    }

    func testEnsureRunningIsIdempotent() throws {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        try controller.ensureRunning(at: beijing)
        try controller.ensureRunning(at: shanghai)

        // 第二次不该重新 bind —— 端口在「先停后起」的空隙里会被别人抢走。
        XCTAssertEqual(core.startCount, 1, "重复调用不应重新启动代理")
        XCTAssertEqual(core.lastPushed?.latitude ?? 0, shanghai.latitude, accuracy: 0.0001,
                       "坐标应当被更新")
    }

    func testEnsureListeningLeavesTargetAlone() throws {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        // 装证书走的是这条路：只要监听，不要目标点。
        try controller.ensureListening()

        XCTAssertEqual(controller.status, .running)
        XCTAssertNil(core.lastPushed, "没有目标点就不应该下发任何改写配置")
    }

    // MARK: - 失败分类

    func testPortInUseIsReportedWithoutTouchingCore() {
        let core = FakeProxyCore()
        core.listening = true
        let controller = makeController(core: core, defaults: makeDefaults())

        XCTAssertThrowsError(try controller.ensureRunning(at: beijing)) { error in
            XCTAssertEqual(error as? ProxyController.Failure, .portInUse)
        }

        XCTAssertEqual(controller.status, .failed(.portInUse))
        XCTAssertEqual(core.startCount, 0, "端口已被占用时不该再去尝试启动")
    }

    func testCertificateFailureMapsToItsOwnCase() {
        let core = FakeProxyCore()
        let authority = FakeAuthority(failure: .generationFailed)
        let controller = makeController(core: core, authority: authority, defaults: makeDefaults())

        XCTAssertThrowsError(try controller.ensureRunning(at: beijing)) { error in
            XCTAssertEqual(error as? ProxyController.Failure,
                           .certificateUnavailable(.generationFailed))
        }

        XCTAssertEqual(core.startCount, 0, "证书都没拿到就不该去尝试启动")
    }

    func testCoreRefusalBecomesStartFailed() {
        let core = FakeProxyCore()
        core.startResult = nil
        let controller = makeController(core: core, defaults: makeDefaults())

        XCTAssertThrowsError(try controller.ensureRunning(at: beijing)) { error in
            XCTAssertEqual(error as? ProxyController.Failure, .startFailed)
        }

        XCTAssertEqual(controller.status, .failed(.startFailed))
    }

    func testEveryFailureCarriesTitleAndAdvice() {
        let failures: [ProxyController.Failure] = [
            .certificateUnavailable(.generationFailed),
            .portInUse,
            .invalidCertificate,
            .startFailed,
        ]
        for failure in failures {
            XCTAssertFalse(failure.title.isEmpty, "\(failure) 缺少标题")
            XCTAssertFalse(failure.advice.isEmpty, "\(failure) 缺少操作指引")
        }
    }

    // MARK: - 改写开关

    func testSetPatchingPushesConfiguration() throws {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        try controller.ensureRunning(at: beijing)
        controller.setPatching(true)

        XCTAssertTrue(controller.isPatching)
        XCTAssertEqual(core.lastPushed?.enabled, true)
        XCTAssertEqual(core.lastPushed?.latitude ?? 0, beijing.latitude, accuracy: 0.0001)
    }

    func testSetPatchingWithoutRunningProxyIsHarmless() {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        controller.setPatching(true)

        // 开关状态记下来（下次启动代理时会带上），但没有代理就不下发。
        XCTAssertTrue(controller.isPatching)
        XCTAssertNil(core.lastPushed)
    }

    // MARK: - 关闭

    func testShutdownReleasesHandleAndClearsPatching() throws {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        try controller.ensureRunning(at: beijing)
        controller.setPatching(true)
        controller.shutdown()

        XCTAssertEqual(controller.status, .stopped)
        XCTAssertEqual(core.stopCount, 1)
        XCTAssertFalse(controller.isPatching)
        XCTAssertNil(controller.failure)
    }

    func testShutdownFlushesCoreLogs() throws {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        try controller.ensureRunning(at: beijing)
        controller.shutdown()

        // 收尾不捞一次，Go 侧最后那批日志（往往正是「为什么停的」）就永远丢了。
        XCTAssertGreaterThan(core.flushedCount, 0)
    }

    // MARK: - 上次状态恢复

    func testRestoreIfNeededRebuildsPreviousSession() throws {
        let defaults = makeDefaults()

        let first = FakeProxyCore()
        let controller = makeController(core: first, defaults: defaults)
        try controller.ensureRunning(at: shanghai)
        controller.setPatching(true)

        // 模拟「App 被上滑清除后重新打开」：新的控制器、同一份偏好。
        let second = FakeProxyCore()
        let restored = makeController(core: second, defaults: defaults)
        restored.restoreIfNeeded()

        XCTAssertEqual(restored.status, .running)
        XCTAssertTrue(restored.isPatching)
        XCTAssertEqual(second.startCount, 1)
        XCTAssertEqual(second.lastPushed?.latitude ?? 0, shanghai.latitude, accuracy: 0.0001,
                       "应当接回上次的目标点")
    }

    func testRestoreIfNeededDoesNothingWithoutHistory() {
        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: makeDefaults())

        controller.restoreIfNeeded()

        XCTAssertEqual(controller.status, .stopped)
        XCTAssertEqual(core.startCount, 0)
    }

    func testShutdownClearsRestoreHistory() throws {
        let defaults = makeDefaults()

        let core = FakeProxyCore()
        let controller = makeController(core: core, defaults: defaults)
        try controller.ensureRunning(at: beijing)
        controller.shutdown()

        // 用户明确点了「关闭代理服务」，下次启动就不该擅自把它接回来。
        let next = FakeProxyCore()
        let reopened = makeController(core: next, defaults: defaults)
        reopened.restoreIfNeeded()

        XCTAssertEqual(reopened.status, .stopped)
        XCTAssertEqual(next.startCount, 0)
    }
}

// MARK: - 假实现

/// 假的 Core：只记录被要求做了什么，不做真的 IO。
///
/// `@unchecked Sendable`：它确实有可变状态，但只在 `@MainActor` 的用例里被
/// 单线程驱动 —— 没有任何一处真的把它并发使用。协议要求 `Sendable` 是因为
/// 真实实现的日志搬运闭包是 `@Sendable` 的，这里跟着标注即可。
final class FakeProxyCore: ProxyCore, @unchecked Sendable {

    /// 端口是否「已被别人占用」。
    var listening = false

    /// 启动结果。设为 `nil` 模拟核心拒绝启动。
    var startResult: UInt? = 1

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var flushedCount = 0

    private(set) var lastPushed: (
        latitude: Double, longitude: Double, enabled: Bool, accuracy: Int, motionRadius: Int
    )?

    private var reported: (latitude: Double, longitude: Double, enabled: Bool) = (0, 0, false)

    func isProxyListening() -> Bool { listening }

    func startProxy(certificate: String, privateKey: String, latitude: Double,
                    longitude: Double, enabled: Bool, accuracy: Int,
                    motionRadius: Int) -> UInt? {
        startCount += 1
        guard let startResult else { return nil }
        listening = true
        reported = (latitude, longitude, enabled)
        return startResult
    }

    @discardableResult
    func stopProxy(handle: UInt) -> Bool {
        stopCount += 1
        listening = false
        return true
    }

    func updatePatchConfig(latitude: Double, longitude: Double,
                           enabled: Bool, accuracy: Int, motionRadius: Int) {
        lastPushed = (latitude, longitude, enabled, accuracy, motionRadius)
        reported = (latitude, longitude, enabled)
    }

    func currentPatchConfig() -> (latitude: Double, longitude: Double, enabled: Bool) {
        reported
    }

    func flushLogs(category: String) { flushedCount += 1 }
}

/// 假的证书来源。
struct FakeAuthority: CertificateProviding {

    var failure: CertificateAuthority.Failure?

    func loadOrCreate() throws -> CertificateAuthority.Material {
        if let failure { throw failure }
        return CertificateAuthority.Material(
            certificate: "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----",
            privateKey: "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----"
        )
    }

    func discardCache() {}
}
