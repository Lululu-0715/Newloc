import Combine
import CoreLocation
import Foundation

/// 内置拦截代理的生命周期与坐标下发。
///
/// ## 这个类存在的唯一理由是那条容易被忽略的因果链
///
/// 用户在「设置 → 无线局域网 → (i) → 配置代理」里填了 `127.0.0.1:8888` 之后，
/// **全机 HTTP/HTTPS 流量都会先送到这个端口**。此时若代理没在监听，后果不是
/// 「定位不生效」，而是**微信、Safari、App Store 全部连不上网**。
///
/// 于是交互被钉死：代理监听**必须常驻**，能自由开合的只有底下的两层 ——
/// 「改写开关」和（另一个类管着的）「校验循环」。
///
/// ```
/// ① 代理监听 127.0.0.1:8888   ← 常驻，只有设置页那个带警告的入口能关
/// ② 改写开关 enabled          ← setPatching，随时开合
/// ③ 校验循环                  ← SpoofEffectVerifier，随时开合
/// ```
///
/// ## 三个状态不是一回事
///
/// | 状态 | 含义 |
/// |---|---|
/// | `handle == nil` | 进程内没有代理对象 |
/// | `isProxyListening()` | 端口**现在**接得上 |
/// | `LinkProbe == .alive` | 代理真的在处理请求 |
///
/// 第三个才是「能用」。前两个是快速过滤：`isProxyListening()` 为 false 一定
/// 没在跑；为 true 却**不代表能用** —— App 被 iOS 挂起时监听 socket 只是不再
/// `accept()`，TCP 握手仍由内核在 backlog 里完成，dial 会假成功。
@MainActor
final class ProxyController: ObservableObject {

    static let shared = ProxyController()

    /// 监听端口。
    ///
    /// **必须与 Go 侧常量、以及用户在 Wi-Fi 设置里填的端口三者一致。**
    /// 改这里要连带重新编译 `liblocationcore.a`（端口在 Go 里是硬编码的），
    /// 所以这一版不做成可配置项。
    ///
    /// `nonisolated`：`Failure.advice` 里要引用它，而嵌套类型**不继承**
    /// 外层的 actor 隔离 —— 不加这一句，编译期就会报「从非隔离上下文访问
    /// 主线程隔离的属性」。它是个 `let` 常量，脱离隔离是安全的。
    nonisolated static let port = 8888

    /// 下发给 WLOC 的水平精度（米）。界面上「定位精度：最高」对应的就是这个值。
    private static let accuracyMeters = 5

    // MARK: - 失败

    /// 代理起不来的原因。**必须分开报** —— 三者的解法毫无关系，
    /// 混成一句「启动失败」用户只能干瞪眼。
    enum Failure: Error, Equatable {

        /// CA 拿不到（生成失败 / Keychain 写不进去）。
        case certificateUnavailable(CertificateAuthority.Failure)

        /// 端口被别人占着 —— 用户装了别的代理工具，或者本 App 的上一份实例还在。
        case portInUse

        /// Go 侧拒绝了这份证书。
        case invalidCertificate

        /// 其它原因（Go 侧返回 0，但端口没被占、证书也是刚校验过的）。
        case startFailed

        var title: String {
            switch self {
            case .certificateUnavailable:
                return AppLocalization.string("根证书不可用")
            case .portInUse:
                return AppLocalization.string("代理端口被占用")
            case .invalidCertificate:
                return AppLocalization.string("根证书不被接受")
            case .startFailed:
                return AppLocalization.string("代理启动失败")
            }
        }

        var advice: String {
            switch self {
            case .certificateUnavailable:
                return AppLocalization.string("到「连接设置」里重建根证书，然后重新安装一次。")
            case .portInUse:
                return AppLocalization.string(
                    "端口 %@ 已被其它程序占用，请先关掉它们再重试。",
                    String(ProxyController.port)
                )
            case .invalidCertificate:
                return AppLocalization.string("到「连接设置」里重建根证书。")
            case .startFailed:
                return AppLocalization.string("请重试；若反复失败，到诊断页复制日志反馈。")
            }
        }
    }

    // MARK: - 状态

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(Failure)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .stopped

    /// 改写开关。与 `status` **正交** —— 代理常驻，改写的开合单独控制。
    @Published private(set) var isPatching = false

    /// 当前失败原因（`status` 不是 `.failed` 时为 nil）。给界面直接取用。
    var failure: Failure? {
        if case .failed(let failure) = status { return failure }
        return nil
    }

    /// 最近一次下发的目标点（**WGS-84**）。冷启动恢复后也有值 —— 读的是盘。
    ///
    /// 界面用它做两件事：冷启动把地图对准改写位置；用户把地图挪走时
    /// 提示「改写仍在原位置生效」。`hasTarget` 没打过标记就返回 nil。
    var lastTarget: CLLocationCoordinate2D? {
        guard defaults.bool(forKey: Key.hasTarget) else { return nil }
        return CLLocationCoordinate2D(
            latitude: defaults.double(forKey: Key.latitude),
            longitude: defaults.double(forKey: Key.longitude)
        )
    }

    // MARK: - 内部

    private let authority: CertificateProviding
    private let linkProbe: LinkProbe
    private let core: ProxyCore
    private let defaults: UserDefaults

    private var handle: UInt?
    private var target: CLLocationCoordinate2D?
    private var logTimer: Timer?

    private enum Key {
        static let hasTarget = "proxy.hasTarget"
        static let latitude = "proxy.targetLatitude"
        static let longitude = "proxy.targetLongitude"
        static let patching = "proxy.patchingEnabled"
    }

    init(
        authority: CertificateProviding = CertificateAuthority.shared,
        linkProbe: LinkProbe = LinkProbe(),
        core: ProxyCore = LiveProxyCore(),
        defaults: UserDefaults = .standard
    ) {
        self.authority = authority
        self.linkProbe = linkProbe
        self.core = core
        self.defaults = defaults
    }

    // MARK: - 对外控制

    /// 确保代理在跑（**幂等**），并把目标坐标下发下去。
    ///
    /// 已经 `running` 时只更新坐标，不重复监听 —— 用户每次点「开始定位」都会
    /// 走到这里，若每次都重新 bind，端口会在「先停后起」的空隙里被别的进程抢走。
    func ensureRunning(at target: CLLocationCoordinate2D) throws {
        self.target = target
        persistTarget(target)

        if handle != nil, core.isProxyListening() {
            pushConfiguration()
            return
        }

        try start()
    }

    /// 只为「装证书 / 配 Wi-Fi 代理」把监听拉起来，**不设目标点**。
    ///
    /// 与 `ensureRunning(at:)` 分开是必要的：装证书这件事与「要改到哪个坐标」
    /// 毫无关系，走 `ensureRunning(at:)` 会顺手把用户已经选好的目标点覆盖掉。
    /// 这么起来的代理 `enabled` 为 false，不会改写任何东西。
    func ensureListening() throws {
        if handle != nil, core.isProxyListening() { return }
        try start()
    }

    /// 只切改写的开合，不动代理监听。
    func setPatching(_ on: Bool) {
        isPatching = on
        defaults.set(on, forKey: Key.patching)

        guard handle != nil else { return }
        pushConfiguration()
        AppLog.info("代理", on ? "改写已开启" : "改写已关闭")
    }

    /// 彻底关闭代理服务。
    ///
    /// **调用方必须先警告用户**：如果 Wi-Fi 里还配着 `127.0.0.1:8888`，
    /// 关掉之后全机网络都会中断。界面上这个入口做成红色 + 二次确认。
    func shutdown() {
        stopLogPump()

        if let handle {
            _ = core.stopProxy(handle: handle)
        }
        handle = nil
        target = nil
        isPatching = false
        status = .stopped

        defaults.removeObject(forKey: Key.hasTarget)
        defaults.set(false, forKey: Key.patching)

        authority.discardCache()
        // 代理没了，上一次探测出来的「链路是通的」就不再成立 —— 不清掉就是撒谎。
        ConnectionDiagnostics.shared.invalidateLink()
        AppLog.info("代理", "代理服务已关闭")
    }

    /// 回到前台后的恢复。
    ///
    /// **不能用 `isProxyListening()` 判断**（原因见类型文档）：要派一次真实的
    /// 链路探测，由「代理到底有没有在处理请求」说话。探测失败就重启一次 ——
    /// 代价只是一次 `listen`，比让用户对着「定位失效」猜要便宜得多。
    func recoverAfterForeground() async {
        guard status.isRunning else { return }

        let evidence = await linkProbe.probe()
        guard evidence != .alive else { return }

        AppLog.warn("代理", "回到前台后链路不通，重启代理服务")
        try? restart()
    }

    /// 上次会话留下过目标点就自动接上。
    ///
    /// **为什么需要它**：App 被用户上滑清除时代理随之消失，而此时 Wi-Fi 里可能
    /// 还配着 `127.0.0.1:8888` —— 用户处在**全机断网**的状态里，还以为是「应用
    /// 坏了」。下次打开就自动把代理接回来，是唯一不依赖用户操作的补救。
    func restoreIfNeeded() {
        guard handle == nil else { return }
        guard defaults.bool(forKey: Key.hasTarget) else { return }

        let coordinate = CLLocationCoordinate2D(
            latitude: defaults.double(forKey: Key.latitude),
            longitude: defaults.double(forKey: Key.longitude)
        )
        let shouldPatch = defaults.bool(forKey: Key.patching)

        do {
            let began = Date()
            try ensureRunning(at: coordinate)
            if shouldPatch { setPatching(true) }
            // 冷启动性能观测：这条耗时 = 证书装载 + 代理启动。预热生效后
            // 应稳定在个位数毫秒；若飙到几百毫秒说明又走了一次完整装载。
            AppLog.debug("代理", "自动恢复完成", details: [
                "elapsed_ms": "\(Int(Date().timeIntervalSince(began) * 1000))",
            ])
            AppLog.info("代理", "已按上次的状态自动恢复代理服务")
        } catch let failure as Failure {
            // 恢复失败不打扰用户：他打开应用多半是想做别的事，
            // 真正的状态会在设置页和诊断页里如实呈现。
            AppLog.warn("代理", "自动恢复代理服务失败", details: ["reason": failure.title])
        } catch let failure as CertificateAuthority.Failure {
            AppLog.warn("代理", "自动恢复代理服务失败：根证书不可用", details: [
                "reason": failure.errorDescription ?? "未知",
            ])
        } catch {
            AppLog.warn("代理", "自动恢复代理服务失败", details: ["error": "\(error)"])
        }
    }

    /// 换掉根证书之后重启代理，让它用上新的一份。
    ///
    /// 重建证书时**必须**走这一步：`startProxy` 是在启动那一刻把 CA 读进去的，
    /// 之后 Keychain 换成新的一份，正在跑的代理手里还是旧的 —— 而旧的已经
    /// 签不出被信任的叶子了，表现为「明明重装了证书却不生效」。
    func reloadCertificate() {
        guard handle != nil else { return }
        try? restart()
    }

    // MARK: - 启停

    private func start() throws {
        // 端口被别人占着时，Go 侧同样只回一个 0 —— 分不清是「被占」还是
        // 「证书坏了」。所以**起之前先探一次**，把这两件事分开。
        if core.isProxyListening() {
            AppLog.warn("代理", "端口 \(Self.port) 已被占用")
            status = .failed(.portInUse)
            throw Failure.portInUse
        }

        let material: CertificateAuthority.Material
        do {
            material = try authority.loadOrCreate()
        } catch let failure as CertificateAuthority.Failure {
            status = .failed(.certificateUnavailable(failure))
            throw Failure.certificateUnavailable(failure)
        }

        status = .starting

        let coordinate = target ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)

        guard let handle = core.startProxy(
            certificate: material.certificate,
            privateKey: material.privateKey,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            enabled: isPatching,
            accuracy: Self.accuracyMeters,
            motionRadius: 0
        ) else {
            // 走到这儿说明端口没被占、证书也是刚过校验的，只可能是别的内部问题。
            AppLog.error("代理", "代理启动失败（端口空闲、证书有效）")
            status = .failed(.startFailed)
            throw Failure.startFailed
        }

        self.handle = handle
        status = .running
        startLogPump()

        // 对账：Swift 以为下发过的坐标，Go 侧真的收到了吗。
        // 两边各自维护状态，这一步是唯一能证明它们没分岔的地方。
        let applied = core.currentPatchConfig()
        AppLog.info("代理", "代理服务已启动", details: [
            "port": "\(Self.port)",
            "lat": String(format: "%.6f", applied.latitude),
            "lon": String(format: "%.6f", applied.longitude),
            "patching": applied.enabled ? "1" : "0",
        ])
    }

    /// 重启代理服务：先停掉正在跑的监听，再起一次。
    ///
    /// **2026-10-15 审查 A5：从 `private` 提为 internal。** 连接设置页那个
    /// 「重启代理服务」按钮原先调的是 `ensureListening()`，而后者在
    /// `handle != nil && core.isProxyListening()` 时**直接 return** ——
    /// 按钮承诺的重启从来没发生过，「换了证书必须重启才生效」也就一直不生效。
    ///
    /// 改成 `throws` 之后调用方能把失败如实报给用户。内部那两个不想打扰用户
    /// 的调用点（`reloadCertificate` / `recoverAfterForeground`）用 `try?`，
    /// 行为与改动前一致 —— `start()` 内部本来就已经把 `status` 落好了。
    func restart() throws {
        stopLogPump()

        if let handle {
            _ = core.stopProxy(handle: handle)
        }
        handle = nil
        status = .stopped

        try start()
    }

    /// 把当前坐标与开关推给 Go 侧。
    private func pushConfiguration() {
        guard let target else { return }

        core.updatePatchConfig(
            latitude: target.latitude,
            longitude: target.longitude,
            enabled: isPatching,
            accuracy: Self.accuracyMeters,
            motionRadius: 0
        )
    }

    // MARK: - 日志搬运

    /// Go 侧的日志积在它自己的环形缓冲里，要主动拉。
    ///
    /// 一秒一次：比这更密是白费电，更疏则用户点完按钮要等半天才看到反馈。
    private func startLogPump() {
        guard logTimer == nil else { return }

        // 先把 core 取出来再进闭包：Timer 被 self 持有，闭包若捕获 self 就成环
        // （self → timer → 闭包 → self）。捕获一个 struct 值则不会。
        let core = self.core
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            core.flushLogs(category: "代理")
        }
    }

    private func stopLogPump() {
        logTimer?.invalidate()
        logTimer = nil

        // 收尾前把最后一批捞出来，否则「代理已停止」前面那些原因就永远丢了。
        core.flushLogs(category: "代理")
    }

    // MARK: - 持久化

    /// 只登记目标坐标、不启动代理 —— 第三方模式下主按钮用它留下
    /// 冷启动对准用的「上次位置」。
    func recordTarget(_ coordinate: CLLocationCoordinate2D) {
        persistTarget(coordinate)
    }

    private func persistTarget(_ coordinate: CLLocationCoordinate2D) {
        defaults.set(true, forKey: Key.hasTarget)
        defaults.set(coordinate.latitude, forKey: Key.latitude)
        defaults.set(coordinate.longitude, forKey: Key.longitude)
    }
}

extension ProxyController {

    /// 把 `Failure` 包成 `Identifiable`，供 `.alert(item:)` 使用。
    ///
    /// 不让 `Failure` 自己实现 `Identifiable`：那个 `id` 只服务于弹窗，
    /// 而 `Failure` 还要被设置页、引导页直接取用 —— 往里塞界面专用的东西不合适。
    struct Alert: Identifiable {
        let id = UUID()
        let failure: Failure
    }
}

// MARK: - Core 能力抽象

/// `ProxyController` 用到的 Core 能力。
///
/// **抽成协议只有一个目的：让状态机能被单测跑完。**
/// 真实的 `CoreBridge` 会真的 bind 端口、真的起 HTTP 服务 —— 那些行为在单测里
/// 既慢又互相干扰（端口只有一个），而这里真正要验证的只是「什么条件下进哪个
/// 状态」。换成假实现，`stopped → running → failed` 整条路径毫秒内就能跑完。
///
/// `Sendable`：日志搬运的定时器回调是 `@Sendable` 的，里面要用这个对象。
/// 它只被 `ProxyController` 在主线程上驱动，真实现 `LiveProxyCore` 是个
/// 无状态 struct，本来就是值语义、天然可跨隔离传递。
protocol ProxyCore: Sendable {

    /// 端口现在接得上吗。
    func isProxyListening() -> Bool

    /// 启动代理，返回句柄；失败返回 `nil`。
    func startProxy(
        certificate: String,
        privateKey: String,
        latitude: Double,
        longitude: Double,
        enabled: Bool,
        accuracy: Int,
        motionRadius: Int
    ) -> UInt?

    /// 停止代理。
    @discardableResult
    func stopProxy(handle: UInt) -> Bool

    /// 下发改写配置。
    func updatePatchConfig(latitude: Double, longitude: Double,
                           enabled: Bool, accuracy: Int, motionRadius: Int)

    /// 读回 Go 侧当前配置。
    func currentPatchConfig() -> (latitude: Double, longitude: Double, enabled: Bool)

    /// 把 Core 侧积压的日志搬进应用日志。
    func flushLogs(category: String)
}

/// 真实实现：原样转发到 Go 桥接层。
struct LiveProxyCore: ProxyCore {

    func isProxyListening() -> Bool {
        CoreBridge.isProxyListening()
    }

    func startProxy(certificate: String, privateKey: String, latitude: Double,
                    longitude: Double, enabled: Bool, accuracy: Int,
                    motionRadius: Int) -> UInt? {
        CoreBridge.startProxy(certificate: certificate, privateKey: privateKey,
                              latitude: latitude, longitude: longitude,
                              enabled: enabled, accuracy: accuracy,
                              motionRadius: motionRadius)
    }

    @discardableResult
    func stopProxy(handle: UInt) -> Bool {
        CoreBridge.stopProxy(handle: handle)
    }

    func updatePatchConfig(latitude: Double, longitude: Double,
                           enabled: Bool, accuracy: Int, motionRadius: Int) {
        CoreBridge.updatePatchConfig(latitude: latitude, longitude: longitude,
                                     enabled: enabled, accuracy: accuracy,
                                     motionRadius: motionRadius)
    }

    func currentPatchConfig() -> (latitude: Double, longitude: Double, enabled: Bool) {
        CoreBridge.currentPatchConfig()
    }

    func flushLogs(category: String) {
        CoreBridge.flushLogs(category: category)
    }
}

/// 根证书来源抽象。与 `ProxyCore` 同理 —— 为了「CA 拿不到」这条分支可测。
protocol CertificateProviding {
    func loadOrCreate() throws -> CertificateAuthority.Material
    func discardCache()
}

extension CertificateAuthority: CertificateProviding {}
