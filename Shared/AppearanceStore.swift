import SwiftUI
import UIKit

/// 外观（浅色 / 深色 / 跟随系统）。
///
/// 和配色主题**分开管理**：主题管品牌色，外观管明暗。
/// 两者是正交的，「深色 + 玫红雪白」是合法组合。
@MainActor
final class AppearanceStore: ObservableObject {

    static let shared = AppearanceStore()

    enum Mode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return AppLocalization.string("跟随系统")
            case .light: return AppLocalization.string("浅色")
            case .dark: return AppLocalization.string("深色")
            }
        }

        /// 交给 `.preferredColorScheme`。`nil` = 跟随系统。
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        /// 这一档在给定系统外观下**实际**会显示成什么。
        /// `colorScheme == nil`（跟随系统）时就是系统那一档。
        func resolved(system: ColorScheme) -> ColorScheme {
            colorScheme ?? system
        }
    }

    private enum Key {
        static let mode = "appearanceMode"
    }

    private let defaults: UserDefaults

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            AppLog.info("外观", "外观已切换", details: ["mode": mode.rawValue])
        }
    }

    // MARK: - 明暗切换

    /// 当前**实际显示**的外观。`.system` 时取系统的。
    var effectiveScheme: ColorScheme {
        mode.resolved(system: Self.systemScheme)
    }

    /// 系统当前的外观。
    private static var systemScheme: ColorScheme {
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }

    /// 在浅色与深色之间切换。
    ///
    /// **为什么不是「浅色 → 深色 → 跟随系统」三档循环**：我一开始就是那么写的，
    /// 还加了一条「点下去看不出变化的那一档自动跳过」，因为
    /// `跟随系统 → 浅色` 在系统本身就是浅色时会让界面纹丝不动。
    ///
    /// 写完单测才发现那个补丁只是掩盖症状：系统是浅色时，
    /// `深色 → 跟随系统`（变浅，有变化，停住）→ `跟随系统 → 浅色`（无变化，跳过）→ 深色，
    /// 于是**永远在「深色 ⇄ 跟随系统」之间来回，浅色这一档再也到不了**；系统是深色时同理，
    /// 丢掉的是「跟随系统」。补丁保证了"每次都有变化"，却把"每档都能到达"给牺牲了。
    ///
    /// 所以退回两态 —— 它才是这个按钮真正在做的事：切明暗。
    /// 「跟随系统」是设置项，留在设置页；这也符合系统惯例：
    /// 一旦手动切过外观，就不该再自动跟随。
    func toggle() {
        mode = Self.opposite(of: mode, system: Self.systemScheme)
    }

    /// 算「另一个」外观。**与系统环境无关的纯函数**，所以能直接单测 ——
    /// `toggle()` 只剩一行，逻辑全在这里。
    ///
    /// 当前是「跟随系统」时按**实际显示**取反，这样第一下点击一定有变化。
    static func opposite(of mode: Mode, system: ColorScheme) -> Mode {
        mode.resolved(system: system) == .dark ? .light : .dark
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 默认**浅色**（2026-10-12 用户拍板）：黑白配色的设计稿画的就是白底黑字，
        // 跟随系统会在深色系统上首启直接进全黑地图，黑白观感就没了。
        let stored = defaults.string(forKey: Key.mode) ?? Mode.light.rawValue
        // 盘里存的值不认识（降级 / 手改过）就回落浅色，并写回盘 ——
        // 不回写的话盘里会一直留着一个取不到的值。
        let resolved = Mode(rawValue: stored) ?? .light
        mode = resolved
        if resolved.rawValue != stored {
            defaults.set(resolved.rawValue, forKey: Key.mode)
        }
    }
}
