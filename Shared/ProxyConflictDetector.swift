import CFNetwork
import Foundation

/// 系统代理冲突检测：内置代理要求 **Wi-Fi 的 HTTP 代理指向 `127.0.0.1:8888`**。
///
/// 如果用户手机上还开着别的代理软件（Surge / 小火箭全局模式等），系统代理
/// 槽位就被它占着 —— 我们的链路直接断，而且现场报错让人看不懂。
/// 所以在开启虚拟定位**之前**先看一眼系统代理（2026-10-12 用户要求）：
/// 指向别处 → 阻断 + 明说原因；指向我们 → 放行；没配 → 放行（新用户）。
enum ProxyConflictDetector {

    /// 一次检测结果。
    struct SystemProxy: Equatable {
        let host: String
        let port: Int
    }

    /// 读取系统全局 HTTP 代理（Wi-Fi「配置代理 → 手动」写进去的那份）。
    ///
    /// `CFNetworkCopySystemProxySettings` 是 CFNetwork 的公开 API，
    /// 只读系统设置，不含任何隐私数据。
    static func systemHTTPProxy() -> SystemProxy? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any] else {
            return nil
        }

        // iOS 上若未启用全局 HTTP 代理，这两个键不存在或 enable 为 0。
        let enabled = settings[kCFNetworkProxiesHTTPEnable as String] as? Int ?? 0
        guard enabled == 1 else { return nil }

        guard let host = settings[kCFNetworkProxiesHTTPProxy as String] as? String,
              let port = settings[kCFNetworkProxiesHTTPPort as String] as? Int else {
            return nil
        }
        return SystemProxy(host: host, port: port)
    }

    /// 是否与内置代理冲突：系统代理已启用、但**不指向本 App**。
    ///
    /// 指向 `127.0.0.1:8888` 就是上一轮我们自己教用户配的，不叫冲突。
    static func conflict(oursHost: String = "127.0.0.1",
                         oursPort: Int = ProxyController.port) -> SystemProxy? {
        guard let proxy = systemHTTPProxy() else { return nil }
        let isOurs = proxy.host == oursHost && proxy.port == oursPort
        return isOurs ? nil : proxy
    }

    /// Wi-Fi 全局 HTTP 代理是否**已经配置成本 App**（`127.0.0.1:8888`）。
    ///
    /// 与 `conflict` 合起来覆盖三种现场：没配（用户以为配了，2026-10-12
    /// 实际踩过：白测半天）/ 配了但被别的软件改掉 / 配好了。
    /// 只有第三种才允许开启虚拟定位。
    static func isConfigured(oursHost: String = "127.0.0.1",
                             oursPort: Int = ProxyController.port) -> Bool {
        guard let proxy = systemHTTPProxy() else { return false }
        return proxy.host == oursHost && proxy.port == oursPort
    }
}
