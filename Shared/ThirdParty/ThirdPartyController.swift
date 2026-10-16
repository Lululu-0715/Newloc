import Foundation

/// 第三方客户端模式的控制器。
///
/// 与内置代理（`ProxyController`）互斥使用：本类不启动任何本地服务，
/// 只向客户端模块的坐标接口发 HTTP 请求 —— 请求经用户客户端的
/// VPN/MITM 隧道被 `wloc-settings.js` 拦截并处理。请求失败或响应
/// 不是我们的 JSON，就说明模块没装好或客户端没开。
@MainActor
final class ThirdPartyController: ObservableObject {

    static let shared = ThirdPartyController()

    enum State: Equatable {
        /// 尚未探测。
        case unknown
        /// 模块未装 / 客户端没开 / 请求失败 —— 链路不通。
        case unreachable
        /// 模块已连接，虚拟定位未开启（query 回 success:false 是正常应答）。
        case moduleIdle
        /// 模块已连接，坐标已写入，改写进行中。
        case active
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var lastError: String?

    /// `wloc.js` 写入的运行诊断。非 nil 说明改写脚本真的在跑 ——
    /// 这是第三方模式最硬的「链路活着」证据（docs/05 决策四的
    /// 探针降级方案因为有这条回显通道而升级为可用探针）。
    @Published private(set) var lastDiag: [String: Any]?

    /// 把 `wloc.js` 的 outcome 翻译成人话（2026-10-13 用户真机反馈：
    /// 之前只显示「已收到」，脚本明明报了「没匹配到/gzip 没解压」这些
    /// 金贵结论却看不到，定位不动时无从下手）。
    ///
    /// nil = 还没有脚本运行记录（改写脚本一次都没被触发过 ——
    /// 这本身就是重要线索：系统定位请求根本没经过客户端）。
    var diagOutcomeText: String? {
        guard let diag = lastDiag else { return nil }
        let locations = (diag["locations"] as? NSNumber)?.intValue ?? 0
        switch (diag["outcome"] as? String) ?? "" {
        case "rewritten":
            return AppLocalization.string(
                "改写成功 · 本次命中 %ld 处", locations)
        case "no-match":
            return AppLocalization.string("脚本跑了，但响应里没找到可改写的位置数据")
        case "gzip":
            return AppLocalization.string("定位响应是 gzip 压缩，当前客户端不支持解压 —— 改写被跳过")
        case "disabled":
            return AppLocalization.string("脚本在跑，虚拟定位未开启")
        case "bad-target":
            return AppLocalization.string("模块里的目标坐标无效，请重新开启虚拟定位")
        case "empty-body":
            return AppLocalization.string("定位响应体为空，脚本放行")
        case "error":
            return AppLocalization.string("脚本运行出错：%@",
                (diag["reason"] as? String) ?? "-")
        default:
            return AppLocalization.string("未知脚本状态")
        }
    }

    private let session: URLSession

    /// 请求要穿过客户端的 VPN 隧道再回到本机，比直连慢，放宽到 10 秒。
    private static let timeout: TimeInterval = 10

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 状态解读

    /// 是否处于「坐标已写入」状态。
    var isActive: Bool { state == .active }

    /// 状态胶囊的文案。
    var statusText: String {
        switch state {
        case .unknown: return AppLocalization.string("模块检测中")
        case .unreachable: return AppLocalization.string("模块未连接")
        case .moduleIdle: return AppLocalization.string("模块已连接")
        case .active: return AppLocalization.string("改写运行中")
        }
    }

    // MARK: - 三个动作

    /// 探测模块：query 一次。拿得到我们的 JSON = 模块在。
    func probe() async {
        guard let json = await request("action=query") else { return }
        apply(json, forProbe: true)
    }

    /// 写入坐标（**WGS-84**，与内置代理下发的口径一致）。
    /// 返回是否成功；失败时 `lastError` 带原因。
    @discardableResult
    func activate(latitude: Double, longitude: Double,
                  accuracy: Int = 25, drift: Int = 0) async -> Bool {
        let query = "lon=\(format(longitude))&lat=\(format(latitude))"
            + "&acc=\(accuracy)&drift=\(drift)"
        guard let json = await request(query) else { return false }
        guard json["success"] as? Bool == true else {
            lastError = (json["error"] as? String) ?? AppLocalization.string("模块拒绝保存")
            state = .unreachable
            return false
        }
        state = .active
        lastError = nil
        return true
    }

    /// 清除坐标（停止虚拟定位）。
    @discardableResult
    func deactivate() async -> Bool {
        guard let json = await request("action=clear") else { return false }
        guard json["success"] as? Bool == true else {
            lastError = (json["error"] as? String) ?? AppLocalization.string("模块拒绝清除")
            return false
        }
        state = .moduleIdle
        lastDiag = json["diag"] as? [String: Any]
        return true
    }

    // MARK: - 界面测试注入口

    /// 只在 Debug 下存在：把状态机强制置为 active 并塞一份样本诊断，
    /// 供模拟器烟测「第三方状态行完整形态」（真实 active 需要手机上的
    /// 代理客户端，模拟器给不了）。Release 不编入。
    ///
    /// 置位后**钉住**状态：主界面 onAppear / 回前台都会自动 probe，
    /// 模拟器上 probe 必然失败，会把注入的状态当场打回 unreachable。
    #if UI_TEST_HOOKS
    private var pinState = false

    func forceActiveForUITest(latitude: Double, longitude: Double) {
        state = .active
        lastError = nil
        pinState = true
        lastDiag = ["outcome": "rewritten",
                    "locations": 6,
                    "env": "shadowrocket",
                    "ts": Int(Date().timeIntervalSince1970 * 1000)]
    }
    #endif

    // MARK: - 私有

    /// 把一次应答映射进状态机。探测（probe）与保存共用。
    private func apply(_ json: [String: Any], forProbe: Bool) {
        #if UI_TEST_HOOKS
        if pinState { return }
        #endif
        lastDiag = json["diag"] as? [String: Any]
        lastError = nil

        // 改写证据喂账本（2026-10-13 校验器换证据源）：脚本报「改写成功」
        // = 目标坐标确实写进了定位响应。按 ts 去重 —— probe 会把同一份
        // 诊断反复读回来，重复记账会让校验器误判「本轮有新改写」。
        if let diag = lastDiag,
           (diag["outcome"] as? String) == "rewritten" {
            let ts = (diag["ts"] as? NSNumber)?.doubleValue ?? 0
            RewriteLedger.shared.observeThirdPartyDiag(tsMilliseconds: ts)
        }

        if json["success"] as? Bool == true {
            // query 成功 = 已开启且坐标在；save 成功也走这里。
            state = .active
        } else {
            // success:false + 我们的 JSON = 模块在、没开（契约约定）。
            state = .moduleIdle
            if let error = json["error"] as? String,
               !error.contains(AppLocalization.string("无已保存的坐标")) {
                lastError = error
            }
        }
    }

    /// 发一次接口请求。返回解析出的 JSON 字典；链路不通返回 nil
    /// （此时状态置为 unreachable）。
    private func request(_ query: String) async -> [String: Any]? {
        var components = URLComponents(url: ThirdPartyConfig.settingsURL,
                                       resolvingAgainstBaseURL: false)!
        components.query = query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.timeout
        // 不缓存：每次都要真实穿过客户端隧道。
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                #if UI_TEST_HOOKS
                if !pinState {
                    state = .unreachable
                    lastError = AppLocalization.string("模块接口响应异常")
                }
                #else
                state = .unreachable
                lastError = AppLocalization.string("模块接口响应异常")
                #endif
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["success"] != nil else {
                // 拿到了应答但不是我们的 JSON —— 说明请求穿过了客户端
                // 但没被 wloc-settings.js 拦截（模块没装 / 没开 / MITM 没配）。
                #if UI_TEST_HOOKS
                if !pinState {
                    state = .unreachable
                    lastError = AppLocalization.string("请求未被模块拦截：请确认模块已导入并启用，且客户端已开启连接")
                }
                #else
                state = .unreachable
                lastError = AppLocalization.string("请求未被模块拦截：请确认模块已导入并启用，且客户端已开启连接")
                #endif
                return nil
            }
            return json
        } catch {
            #if UI_TEST_HOOKS
            if !pinState {
                state = .unreachable
                lastError = AppLocalization.string("连不上模块：请确认客户端已开启连接（VPN）且本模块已启用")
            }
            #else
            state = .unreachable
            lastError = AppLocalization.string("连不上模块：请确认客户端已开启连接（VPN）且本模块已启用")
            #endif
            return nil
        }
    }

    /// 坐标格式化：脚本是严格转数值，这里定长小数避免科学计数法。
    private func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
