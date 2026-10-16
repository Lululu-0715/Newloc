import Darwin
import Foundation

/// Go 核心（`liblocationcore.a`）的 Swift 封装。
///
/// 所有跨语言调用都集中在这里，好处是内存管理（`free`）和错误转换只有一处，
/// 上层业务代码完全看不到 C 指针。
///
/// **注意**：`Core/locationcore.h` 由 `Scripts/build-core.sh` 从 Go 侧生成，
/// 不手写、不提交。这里调用的每个符号都要在 `Core/bridge.go` 里有对应的
/// `//export` —— 缺了是**链接期**符号缺失，编译器不会提前告诉你。
enum CoreBridge {

    /// Core 的版本号，用于确认静态库与 Swift 代码匹配。
    static var coreVersion: String {
        guard let pointer = locationcore_version() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - 日志

    /// 把 Core 侧积压的日志搬到 Swift 日志系统。
    ///
    /// Go 侧的回调发生在任意线程，且是**同步**调用回来，所以这里不做任何
    /// 异步包装 —— 顺序本身就是日志的价值所在。
    static func flushLogs(category: String) {
        for line in drainLogLines() {
            // 改写证据就在这批日志里（"WLOC 已改写 …"）。这里是**唯一**的
            // 日志出口（日志泵、停机收尾都走它），账本在这喂入不会被
            // drain 语义抢漏 —— 每行先记嫌疑再落普通日志。
            RewriteLedger.shared.observeBuiltinLogLine(line)
            AppLog.info(category, line)
        }
    }

    /// 拉取并清空 Core 积压日志，按行返回。
    ///
    /// 单独拆出来是因为 `flushLogs` 有第二个消费者（校验器的改写证据）——
    /// `drainLogs` 是取走即清空的语义，两个消费者必须共用**同一次**拉取，
    /// 不能各拉各的，否则互相把对方的日志吃掉。
    static func drainLogLines() -> [String] {
        guard let pointer = locationcore_drainlogs() else { return [] }
        defer { free(pointer) }
        return String(cString: pointer)
            .split(separator: "\n")
            .map(String.init)
    }

    // MARK: - 代理连通性验证

    /// 刷新一次性验证 token，返回新值。
    static func refreshVerifyToken() -> String {
        guard let pointer = locationcore_refreshverifytoken() else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// 检查 token 是否为当前有效值。
    static func checkVerifyToken(_ token: String) -> Bool {
        token.withCString { locationcore_checkverifytoken(UnsafeMutablePointer(mutating: $0)) != 0 }
    }

    /// 实际探一次代理端口是否还在监听。
    ///
    /// Swift 侧的运行状态是**自维护**的：进程被 iOS 挂起时，Go 侧的监听
    /// socket 会失效，但两边都不会自动把状态改成「已停止」。所以判断代理
    /// 是否可用**必须以本函数的实测结果为准**，不能只看状态值。
    static func isProxyListening() -> Bool {
        locationcore_isproxylistening() != 0
    }

    // MARK: - 根证书

    /// 生成一套全新的自签根证书，返回 PEM 文本。
    ///
    /// **两个返回值都必须释放** —— Go 侧用 `C.CString` 各分配了一块内存，
    /// 少释放一个就是每次重建证书泄漏一块。这里集中在 `defer` 里处理，
    /// 上层拿到的已经是 Swift `String`，看不到指针。
    static func generateCA() -> (certificate: String, privateKey: String)? {
        let result = locationcore_generateca()

        guard let certificatePointer = result.r0,
              let keyPointer = result.r1 else {
            // 只成功一半时也要把已经分配出来的那块释放掉。
            if let certificatePointer = result.r0 { free(certificatePointer) }
            if let keyPointer = result.r1 { free(keyPointer) }
            return nil
        }
        defer {
            free(certificatePointer)
            free(keyPointer)
        }
        return (String(cString: certificatePointer), String(cString: keyPointer))
    }

    /// 校验一对证书 / 私钥是否真的能配套使用。
    static func validateCA(certificate: String, privateKey: String) -> Bool {
        certificate.withCString { certificatePointer in
            privateKey.withCString { keyPointer in
                locationcore_validateca(
                    UnsafeMutablePointer(mutating: certificatePointer),
                    UnsafeMutablePointer(mutating: keyPointer)
                ) != 0
            }
        }
    }

    // MARK: - 代理生命周期

    /// 启动拦截代理，返回后续用于停止的句柄；失败返回 `nil`。
    ///
    /// **失败原因不在这里区分** —— Go 侧只会回一个 0，是端口被占还是 CA 坏了，
    /// 得由调用方结合 `isProxyListening()` 判（见 `ProxyController`）。
    /// 桥接层只做翻译，不做判断。
    static func startProxy(
        certificate: String,
        privateKey: String,
        latitude: Double,
        longitude: Double,
        enabled: Bool,
        accuracy: Int,
        motionRadius: Int
    ) -> UInt? {
        let handle = certificate.withCString { certificatePointer in
            privateKey.withCString { keyPointer in
                locationcore_startproxyv2(
                    UnsafeMutablePointer(mutating: certificatePointer),
                    UnsafeMutablePointer(mutating: keyPointer),
                    CDouble(latitude),
                    CDouble(longitude),
                    enabled ? 1 : 0,
                    CInt(accuracy),
                    CInt(motionRadius)
                )
            }
        }
        return handle == 0 ? nil : handle
    }

    /// 停止代理并释放 Go 侧句柄。
    static func stopProxy(handle: UInt) -> Bool {
        locationcore_stopproxy(handle) == 0
    }

    /// 读回 Go 侧当前生效的改写配置。
    ///
    /// 用于核对「Swift 以为下发过的坐标」与「Go 侧真的收到的坐标」是否一致 ——
    /// 两边各自维护状态，出了问题必须能对账。
    static func currentPatchConfig() -> (latitude: Double, longitude: Double, enabled: Bool) {
        let result = locationcore_getcoords()
        return (result.r0, result.r1, result.r2 != 0)
    }

    // MARK: - 证书服务

    /// 启动证书服务（端口由系统随机分配），返回句柄；失败返回 `nil`。
    ///
    /// 它提供两个端点：`/ca.cer` 供 Safari 下载根证书；`/health` 由 CA 签出的
    /// 叶子证书提供 TLS —— **后者是「根证书到底信没信」唯一干净的判据**，
    /// 因为它绕开 Wi-Fi 代理，直接连本机随机端口。
    static func startCertService(certificate: String, privateKey: String) -> UInt? {
        let handle = certificate.withCString { certificatePointer in
            privateKey.withCString { keyPointer in
                locationcore_startcertservice(
                    UnsafeMutablePointer(mutating: certificatePointer),
                    UnsafeMutablePointer(mutating: keyPointer)
                )
            }
        }
        return handle == 0 ? nil : handle
    }

    static func certServiceHTTPPort(_ handle: UInt) -> Int {
        Int(locationcore_certservice_httpport(handle))
    }

    static func certServiceHTTPSPort(_ handle: UInt) -> Int {
        Int(locationcore_certservice_httpsport(handle))
    }

    static func stopCertService(_ handle: UInt) -> Bool {
        locationcore_stopcertservice(handle) == 0
    }

    // MARK: - 改写配置

    /// 更新改写配置（坐标、开关、精度、抖动半径）。
    static func updatePatchConfig(
        latitude: Double,
        longitude: Double,
        enabled: Bool,
        accuracy: Int,
        motionRadius: Int
    ) {
        locationcore_setpatchconfig(
            CDouble(latitude),
            CDouble(longitude),
            enabled ? 1 : 0,
            CInt(accuracy),
            CInt(motionRadius)
        )
    }
}
