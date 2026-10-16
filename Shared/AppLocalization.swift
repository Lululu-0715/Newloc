import Foundation

/// 本地化查表。
///
/// 约定：**key 就是简体中文原文**。这样源码里读起来就是中文，
/// 不用为了找一句话在 strings 文件和代码之间来回跳；
/// 简体中文包可以是空的（原文即译文），只有 en / zh-Hant 需要真写。
enum AppLocalization {

    static func string(_ key: String) -> String {
        localizedString(key, fallback: key)
    }

    /// 带格式参数的版本（例如「已生效 · %@」）。
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localizedString(key, fallback: key), arguments: arguments)
    }

    // MARK: - 应用内语言覆盖（设置 → 语言）

    /// 覆盖 bundle 的查表状态。`NSLock` 保护 —— 本地化文案可能在
    /// 非主线程被求值（校验器状态文案等），不能赌调用方都在主线程。
    private static let gate = LanguageGate()

    /// 设置应用内语言覆盖。`nil` = 跟随系统。
    static func setOverrideLanguage(_ languageCode: String?) {
        gate.setOverride(languageCode)
    }

    private static func localizedString(_ key: String, fallback: String) -> String {
        if let bundle = gate.overrideBundle() {
            return bundle.localizedString(forKey: key, value: fallback, table: nil)
        }
        return NSLocalizedString(key, comment: "")
    }

    /// 覆盖语言的 bundle 查找与缓存。
    private final class LanguageGate {

        private let lock = NSLock()
        private var overrideCode: String?
        private var cachedBundle: Bundle?

        func setOverride(_ code: String?) {
            lock.lock()
            defer { lock.unlock() }
            if code != overrideCode {
                overrideCode = code
                cachedBundle = nil
            }
        }

        /// 返回覆盖语言的 bundle；未覆盖或找不到 lproj 时返回 nil（走系统语言）。
        func overrideBundle() -> Bundle? {
            lock.lock()
            defer { lock.unlock() }

            guard let code = overrideCode else { return nil }
            if let cached = cachedBundle { return cached }

            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return nil
            }
            cachedBundle = bundle
            return bundle
        }
    }
}
