import Combine
import Foundation

/// 校验功能的开关。
///
/// 「给校验器加个开关」这件事落在这里，分两层：
///
///   - `autoVerifyEnabled` —— **总开关**。关掉之后不再做持续重试：
///     点一次「开始定位」仍然会给一次结论，只是不再每 3 秒回读一遍。
///   - `reverifyOnForeground` —— 回到前台时是否自动重校验。
///     这个开关只在总开关打开时有意义。
///
/// **为什么总开关要存在**：校验会周期性回读定位，每一次都在系统的定位
/// 使用记录里留一笔。有些用户只是偶尔用一次，不想要这份持续记录；
/// 也有些用户嫌反复探测费电。关掉之后应用仍然完整可用。
@MainActor
final class VerificationSettings: ObservableObject {

    static let shared = VerificationSettings()

    private enum Key {
        static let autoVerify = "verification.autoEnabled"
        static let reverifyOnForeground = "verification.reverifyOnForeground"
    }

    /// 自动校验总开关。默认**开**。
    @Published var autoVerifyEnabled: Bool {
        didSet { defaults.set(autoVerifyEnabled, forKey: Key.autoVerify) }
    }

    /// 回到前台是否自动重新校验。默认**开**。
    @Published var reverifyOnForeground: Bool {
        didSet { defaults.set(reverifyOnForeground, forKey: Key.reverifyOnForeground) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 先注册默认值，再读取 —— 首次安装时 `bool(forKey:)` 会返回 false，
        // 不注册的话总开关默认就是关的，用户一进来发现校验不工作。
        defaults.register(defaults: [
            Key.autoVerify: true,
            Key.reverifyOnForeground: true,
        ])

        // 注意：`init` 里给属性赋值**不会**触发 `didSet`，所以这里不会白写一遍。
        self.autoVerifyEnabled = defaults.bool(forKey: Key.autoVerify)
        self.reverifyOnForeground = defaults.bool(forKey: Key.reverifyOnForeground)
    }
}
