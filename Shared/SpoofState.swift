import SwiftUI

/// 虚拟定位的当前结论。
///
/// 四态与 `StatusTint` 的四种语义色**一一对应**：状态是唯一的真相来源，
/// 颜色只是它的表现。任何地方要显示颜色，都先问「现在是什么状态」。
enum SpoofState: Equatable {

    /// 未开始（或已停止）。
    case idle

    /// 正在校验。
    case verifying

    /// 已确认生效。
    case effective

    /// 未生效，带具体原因。
    case ineffective(IneffectiveReason)

    var tint: StatusTint {
        switch self {
        case .idle: return .idle
        case .verifying: return .verifying
        case .effective: return .effective
        case .ineffective: return .ineffective
        }
    }

    var text: String {
        switch self {
        case .idle:
            return AppLocalization.string("未验证")
        case .verifying:
            return AppLocalization.string("验证中")
        case .effective:
            return AppLocalization.string("已生效")
        case .ineffective(let reason):
            return reason.text
        }
    }
}

/// 「未生效」的具体原因。
///
/// **分档是这一版的重点。** 上一版只有「定位服务或权限未开」一句提示，
/// 把几件不同的事混成一个说法：
///
/// 1. 系统**总开关**关着 —— 用户主动去关的，属于正常操作过程；
/// 2. 本应用**没有授权** —— 需要用户在本应用上做选择；
/// 3. 被**限制**（家长控制 / MDM）—— 用户自己解决不了；
/// 4. **代理没接上** —— 改写压根没上路；
/// 5. **系统没刷新** —— 改写上去了，但系统仍用着旧位置。
///
/// 第 1 种是上一版最费解的那条文案的根：引导词恰好教用户「去把定位服务关一下
/// 再打开」，而校验器一读到 `.denied` 就当场结案 —— 用户每照着做一次，
/// 就必然被误报一次「权限未开」。分档之后它**不结案**，只是暂停。
///
/// 第 4 与第 5 种是这一版新拆出来的。上一版把它们压成同一个
/// `stillRealLocation`，配一条「请确认代理已开启、证书已信任」——
/// 可这两件事的解法完全不同：前者要去查代理和证书，后者要去刷系统缓存。
/// 混在一起说，用户读完不知道自己该动哪一头。
enum IneffectiveReason: Equatable {

    /// 系统定位服务总开关关着。**暂时状态，不结案。**
    case systemServicesOff

    /// 本应用没有定位权限。需要用户去设置里授权。
    case permissionDenied

    /// 被家长控制 / MDM 限制，用户无法自行解决。
    case restricted

    /// 代理链路不通：改写没有上路。
    ///
    /// 证据来源是**链路探针**（经代理发一个请求、看能不能被改写回显），
    /// 或者代理层实测到的 TLS 握手失败。不是靠回读定位推断出来的。
    case proxyUnreachable

    /// 改写已经上路，但系统仍用着旧位置（`locationd` 的缓存没刷新）。
    ///
    /// 证据是「链路探针为活」+「回读不到目标点」这对组合。
    case systemNotResolved

    var text: String {
        switch self {
        case .systemServicesOff:
            return AppLocalization.string("定位服务已关闭")
        case .permissionDenied:
            return AppLocalization.string("未授予定位权限")
        case .restricted:
            return AppLocalization.string("定位被限制")
        case .proxyUnreachable:
            return AppLocalization.string("代理未接上")
        case .systemNotResolved:
            return AppLocalization.string("系统未刷新")
        }
    }

    /// 给用户的操作指引。
    var advice: String {
        switch self {
        case .systemServicesOff:
            return AppLocalization.string("把系统定位服务打开即可，应用会自动继续校验。")
        case .permissionDenied:
            return AppLocalization.string("到「设置 → 隐私与安全性 → 定位服务」允许 Newloc 使用定位。")
        case .restricted:
            return AppLocalization.string("设备启用了访问限制，需要管理员解除后才能使用定位。")
        case .proxyUnreachable:
            return AppLocalization.string("改写没有走上去：请确认代理已开启、根证书已信任，然后重新验证。")
        case .systemNotResolved:
            // 刷缓存这一招**随系统版本变了**：iOS ≤ 25 是关开总开关，
            // iOS 26+ 只能重启设备。文案写错方向，用户会把「操作无效」
            // 读成「功能坏了」。
            if SystemCompat.locationToggleFlushesCache {
                return AppLocalization.string(
                    "改写已经走上去了，是系统还没重新解算位置：到「设置 → 隐私与安全性 → 定位服务」关一下再打开。"
                )
            }
            if SystemCompat.mitmMayBeRestricted {
                return AppLocalization.string(
                    "改写已经走上去了，但系统仍未采用新位置。请先重启设备；仍不生效请到诊断页看有没有 TLS 握手失败。"
                )
            }
            return AppLocalization.string(
                "改写已经走上去了，是系统还没重新解算位置：重启设备后再回到本应用验证。"
            )
        }
    }

    /// 这个原因是否只是**暂时**的。
    ///
    /// 暂时性原因**不允许结案** —— 校验时钟暂停、探测次数不消耗，
    /// 等用户把总开关开回来继续。
    var isTransient: Bool {
        switch self {
        case .systemServicesOff: return true
        case .permissionDenied, .restricted, .proxyUnreachable, .systemNotResolved: return false
        }
    }
}
