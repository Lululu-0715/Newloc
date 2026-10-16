import Foundation

/// 系统能力判断的**唯一入口**。
///
/// **为什么集中在一处**：上一版把版本判断散在十几个文件里，有的用 `#available`、
/// 有的读 `ProcessInfo`，同一件事出现两套标准 —— 排查时根本说不清
/// 「到底哪段代码在管这件事」。
///
/// **一条铁律**：这里只判断**能力**，不判断 **beta 序号**。
/// `ProcessInfo` 给得到 `27.0`，但拿不到 beta 号 —— 而 beta 1~5 是可用的，
/// 写成「27 就拦截」会把可用区间一起误伤。
/// 「是否真的被系统封了」由代理层**实测 TLS 握手成败**判定（证据驱动），
/// 版本号只用来决定给用户看什么引导文案。
enum SystemCompat {

    // MARK: - 版本

    static var version: OperatingSystemVersion {
        ProcessInfo.processInfo.operatingSystemVersion
    }

    static var majorVersion: Int { version.majorVersion }

    /// 例如 `17.4.1`。
    static var versionDescription: String {
        let v = version
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - 定位缓存

    /// 关开定位服务总开关，能否刷新 `locationd` 的坐标缓存。
    ///
    /// **iOS 26 起失效** —— 必须重启设备。这是系统的行为变更，不是配置问题，
    /// 也不是应用能绕过的。
    ///
    /// 这条判断直接决定引导词怎么写：在 iOS ≤25 上教用户「关一下再打开」
    /// 是有效且快速的操作；在 iOS 26+ 上教同样的话，用户照着做完
    /// 会发现毫无变化，然后认为应用坏了。
    static var locationToggleFlushesCache: Bool { majorVersion < 26 }

    /// 刷新定位缓存的操作建议（给引导页用）。
    static var cacheFlushAdvice: String {
        if locationToggleFlushesCache {
            return AppLocalization.string("到「设置 → 隐私与安全性 → 定位服务」关一下再打开，即可刷新定位缓存。")
        }
        return AppLocalization.string("系统从 iOS 26 起不再响应「关开定位服务」，需要重启设备才能刷新定位缓存。")
    }

    // MARK: - 描述文件安装入口

    /// 描述文件安装入口的路径（引导文案用）。
    ///
    /// **名字随版本变了**：iOS 15 叫「描述文件与设备管理」，iOS 16 起改名
    /// 「VPN 与设备管理」。名字写错，用户的处境是「照做但找不到入口」——
    /// 这种挫败感比「明确告诉你还没做」还糟。
    static var profileSettingsPath: String {
        if majorVersion >= 16 {
            return AppLocalization.string("设置 → 通用 → VPN 与设备管理")
        }
        return AppLocalization.string("设置 → 通用 → 描述文件与设备管理")
    }

    // MARK: - 证书限制

    /// 系统是否可能给 WLOC 中间人证书加了额外限制。
    ///
    /// **只用于文案，不用于功能拦截。** 见文件头的说明。
    /// 真正的判定在 `ProxyController` 侧：代理层实测到 TLS 握手失败，
    /// 才下「系统拒绝我们的证书」这个结论。
    static var mitmMayBeRestricted: Bool { majorVersion >= 27 }

    /// 代理层上报「证书被拒」时给用户的解释。
    static var certificateRestrictionAdvice: String {
        AppLocalization.string("系统拒绝了本地代理的证书。这是系统级限制，与本机设置无关。")
    }
}
