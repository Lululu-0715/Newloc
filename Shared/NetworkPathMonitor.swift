import Foundation
import Network

/// 当前网络路径监测：虚拟定位的内置代理依赖 **Wi-Fi 的 HTTP 代理设置**，
/// 蜂窝网络下系统根本没有这个配置入口 —— 用户开了也是白开。
///
/// 所以主按钮在「非 Wi-Fi」时禁用并给提示（2026-10-12 用户要求）。
@MainActor
final class NetworkPathMonitor: ObservableObject {

    static let shared = NetworkPathMonitor()

    /// 当前默认路径是否走 Wi-Fi。
    @Published private(set) var isWiFi: Bool = true

    /// 是否有过一次真实结论（启动后第一次回调之前先按 true 顶住，
    /// 避免冷启动闪一下禁用态）。
    @Published private(set) var hasResult: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "newloc.network.monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self else { return }
                self.isWiFi = wifi
                self.hasResult = true
                if !wifi {
                    AppLog.info("网络", "当前默认路径不是 Wi-Fi，内置代理不可用")
                }
            }
        }
        monitor.start(queue: queue)
    }
}
