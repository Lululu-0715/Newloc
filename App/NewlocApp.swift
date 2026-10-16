import SwiftUI

@main
struct NewlocApp: App {

    /// 是否看过欢迎页。存 `UserDefaults` 而不是内存：
    /// 用户第二次打开不该再被引导一遍。
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false

    @StateObject private var appearanceStore = AppearanceStore.shared
    @StateObject private var displayPreferences = DisplayPreferences.shared

    init() {
        // 冷启动性能（2026-10-13）：把根证书的「读盘 + 校验（必要时生成）」
        // 提前到进程起点就在后台线程做。此前这条链全部压在主界面的
        // onAppear 里同步跑 —— 读两个 PEM 文件再跨一次 Go 校验，
        // 用户看到的就是「图标点开到界面出来」之间多出的一截白等。
        // loadOrCreate 有锁且幂等，预热完成后主线程的同步调用直接命中缓存；
        // 万一预热还没完，调用方照旧等锁，结果不劣于优化前。
        Task.detached(priority: .userInitiated) { [authority = CertificateAuthority.shared] in
            _ = try? authority.loadOrCreate()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedWelcome {
                    MapHomeView()
                } else {
                    WelcomeView {
                        // 首启即申请定位权限（2026-10-12 用户要求），
                        // 不等用户自己去点「实时位置」才弹。
                        LocationPermission.requestIfNeeded()
                        hasCompletedWelcome = true
                    }
                }
            }
            // 主题环境挂在根上，全树子视图都能拿到 `themeAccent`。
            .withThemeEnvironment()
            // 外观挂在内容根上：`.preferredColorScheme` 只有作用在
            // WindowGroup 的内容根才影响整个窗口，挂到子视图上只影响那一支。
            .preferredColorScheme(appearanceStore.mode.colorScheme)
            // 语言 / 字号是构建时求值的（AppLocalization / Font.app），
            // 变更后靠根重建生效 —— revision 在任一项变更时 +1。
            .id(displayPreferences.revision)
        }
    }
}
