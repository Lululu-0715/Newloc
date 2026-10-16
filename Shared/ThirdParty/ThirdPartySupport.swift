import Foundation
import SwiftUI

/// 第三方模块的托管配置与客户端定义。
///
/// 数据流（与上一代同源、已验证的设计）：
/// 模块外壳（5 种客户端格式）从 CDN 拉两份脚本 —— `wloc.js` MITM 改写
/// Apple 定位响应，`wloc-settings.js` 提供坐标存取接口
/// （`gs-loc.apple.com/wloc-settings/save?action=save|query|clear`）。
/// 本 App 只负责向该接口写坐标 / 探测模块状态，改写本身发生在客户端里。
enum ThirdPartyConfig {

    /// GitHub 仓库（`owner/repo`）。
    ///
    /// **唯一需要用户建好仓库后修改的地方**：模块外壳、引导页里的
    /// 导入地址全部由它推导。jsDelivr 要求仓库必须是 public。
    static let githubRepo = "Lululu-0715/Newloc"

    static let branch = "main"

    /// 脚本 CDN 根地址（jsDelivr，国内可直连）。
    static var cdnBase: String {
        "https://cdn.jsdelivr.net/gh/\(githubRepo)@\(branch)/ThirdParty/ProxyScripts"
    }

    /// 坐标存取接口（模块的 `wloc-settings.js` 拦截这个路径）。
    static var settingsURL: URL {
        URL(string: "https://gs-loc.apple.com/wloc-settings/save")!
    }
}

// MARK: - 客户端定义

/// 支持的第三方代理客户端。rawValue 同时用作持久化键值。
enum ThirdPartyClient: String, CaseIterable, Identifiable {
    case shadowrocket
    case surge
    case egern
    case quantumultx
    case loon
    case stash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .surge: return "Surge"
        case .egern: return "Egern"
        case .quantumultx: return "Quantumult X"
        case .loon: return "Loon"
        case .stash: return "Stash"
        }
    }

    /// 模块外壳文件（`modules/` 目录下，5 个文件对应 6 家客户端，
    /// Surge 与 Egern 共用 sgmodule）。
    var moduleFile: String {
        switch self {
        case .shadowrocket: return "wloc.module"
        case .surge, .egern: return "wloc.sgmodule"
        case .quantumultx: return "wloc.conf"
        case .loon: return "wloc.lpx"
        case .stash: return "wloc.stoverride"
        }
    }

    /// 客户端「导入模块」里要粘贴的订阅地址。
    var importURL: URL {
        URL(string: "\(ThirdPartyConfig.cdnBase)/modules/\(moduleFile)")!
    }

    /// 唤起客户端的 URL scheme（Info.plist 的 LSApplicationQueriesSchemes 已白名单）。
    var openScheme: String? {
        switch self {
        case .shadowrocket: return "shadowrocket"
        case .surge: return "surge"
        case .egern: return "egern"
        case .quantumultx: return "quantumult-x"
        case .loon: return "loon"
        case .stash: return "stash"
        }
    }

    /// 安装引导步骤（引导页逐条显示）。
    var installSteps: [String] {
        let common = [
            AppLocalization.string("在 App 内复制上面的导入地址"),
            AppLocalization.string("打开客户端，进入「模块 / 插件 / 重写」页，选择「从 URL 导入」并粘贴地址"),
            AppLocalization.string("导入后开启本模块"),
        ]
        switch self {
        case .shadowrocket:
            return common + [
                AppLocalization.string("设置 → MITM：开启 HTTPS 解密，证书按客户端指引安装并信任"),
                AppLocalization.string("首页开启连接（VPN 图标出现）"),
            ]
        case .surge, .egern:
            return common + [
                AppLocalization.string("确认 MITM 已开启且主机名包含 gs-loc.apple.com"),
                AppLocalization.string("首页开启出站连接"),
            ]
        case .quantumultx:
            return common + [
                AppLocalization.string("重写资源里确认规则已启用，HTTPS 解密已开启"),
                AppLocalization.string("首页开启 VPN 连接"),
            ]
        case .loon:
            return common + [
                AppLocalization.string("插件页确认 MITM 已开启"),
                AppLocalization.string("首页开启连接"),
            ]
        case .stash:
            return common + [
                AppLocalization.string("确认 HTTPS 解密（MITM）已安装并信任证书"),
                AppLocalization.string("首页开启连接"),
            ]
        }
    }
}

// MARK: - 运行模式存储

/// 运行模式（内置代理 / 第三方客户端）与所选客户端的持久化。
@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()

    enum Mode: String {
        case builtIn
        case thirdParty

        var displayName: String {
            switch self {
            case .builtIn: return AppLocalization.string("内置代理")
            case .thirdParty: return AppLocalization.string("第三方客户端")
            }
        }
    }

    private static let modeKey = "runMode"
    private static let clientKey = "thirdPartyClient"

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    @Published var client: ThirdPartyClient {
        didSet { UserDefaults.standard.set(client.rawValue, forKey: Self.clientKey) }
    }

    /// 仅供测试与预览注入默认值。
    init(mode: Mode = .builtIn, client: ThirdPartyClient = .shadowrocket) {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey)
        self.mode = Mode(rawValue: raw ?? "") ?? mode
        let rawClient = UserDefaults.standard.string(forKey: Self.clientKey)
        self.client = ThirdPartyClient(rawValue: rawClient ?? "") ?? client
    }
}
