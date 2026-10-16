import CoreLocation
import Foundation

/// 定位权限的一次性申请。
///
/// 2026-10-12 用户要求：**新装首次启动就要弹「允许定位」** ——
/// 以前只在点「实时位置」浮标时才申请（`RealLocationProvider` 里），
/// 用户第一次打开全程遇不到弹窗，还以为定位是坏的。
///
/// 只在「还没问过」时申请；允许 / 拒绝过就再也不打扰，
/// 拒绝后的引导走「实时位置」失败时的弹窗（那里有去设置的入口）。
@MainActor
enum LocationPermission {

    /// 必须持有实例：`CLLocationManager` 被释放后弹窗可能不出现。
    private static let manager = CLLocationManager()

    /// 烟测是否要求**压住定位授权弹窗**。
    ///
    /// 模拟器里没人能点系统弹窗，它会浮在整页之上把截图全部作废 ——
    /// 所以截图时把它按住。两种传法都认：
    ///   - `SIMCTL_CHILD_UITEST_SKIP_LOCATION=1 simctl launch ...`（环境变量，推荐）
    ///   - `... -uiTest.skipLocationPrompt 1`（启动参数）
    /// 非 Debug 构建恒为 `false`（`UI_TEST_HOOKS` 只在 Debug 定义）。
    static var isPromptSuppressed: Bool {
        #if UI_TEST_HOOKS
        if ProcessInfo.processInfo.environment["UITEST_SKIP_LOCATION"] != nil { return true }
        return UserDefaults.standard.string(forKey: "uiTest.skipLocationPrompt") != nil
        #else
        return false
        #endif
    }

    static func requestIfNeeded() {
        #if UI_TEST_HOOKS
        AppLog.info("烟测", "requestIfNeeded", details: ["suppressed": "\(isPromptSuppressed)"])
        #endif
        guard !isPromptSuppressed else { return }
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }
}
