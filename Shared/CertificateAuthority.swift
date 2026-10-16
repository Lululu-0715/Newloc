import Foundation

/// 根证书的持有者：生成、持久化、装载、重建。
///
/// ## 为什么存文件而不是 Keychain
///
/// 最初写的是 Keychain（`kSecClassGenericPassword`），理由是「私钥是这套 MITM
/// 的全部安全性所在，值得更好的保护」。实测推翻了它：
///
/// ```
/// [信息][证书] 没有可用的根证书，开始生成
/// [错误][证书] 根证书写入钥匙串失败 ["status": "-34018"]
/// ```
///
/// `-34018` 是 `errSecMissingEntitlement`。**未签名的 App 访问不到 Keychain** ——
/// 它需要 `keychain-access-groups` entitlement，而 entitlement 只能由签名带进来。
/// 本项目的主要分发方式恰恰是未签名构建（签名交给使用者在 Impactor /
/// 爱思助手里完成），也就是说这条路上 Keychain **在开发期就不可用**，
/// 上了真机也取决于用户怎么签。
///
/// 改用文件之后：
///   * 未签名、自签、企业签，一律可用；
///   * `.completeFileProtectionUntilFirstUserAuthentication` 提供与 Keychain
///     的 `kSecAttrAccessibleAfterFirstUnlock` **等价**的保护等级 ——
///     设备锁定期间同样读不到私钥；
///   * 可在模拟器里完整验证。
///
/// 用 `...UntilFirstUserAuthentication` 而不是 `.completeFileProtection`：
/// 后者在设备锁定期间完全不可读，而「回到前台自动恢复代理」可能发生在
/// 解锁动画还没走完的时候。
final class CertificateAuthority {

    static let shared = CertificateAuthority()

    /// 一对配套的证书与私钥（PEM 文本）。
    struct Material: Equatable {
        let certificate: String
        let privateKey: String
    }

    enum Failure: LocalizedError, Equatable {

        /// Go 侧生成失败，或生成出来的一对无法通过自校验。
        case generationFailed

        /// 读写应用目录失败。细节记在日志里，这里只给用户一句话。
        case storageFailed

        var errorDescription: String? {
            switch self {
            case .generationFailed:
                return AppLocalization.string("根证书生成失败。")
            case .storageFailed:
                return AppLocalization.string("根证书无法保存到应用目录。")
            }
        }
    }

    private enum File {
        static let certificate = "root-ca.crt"
        static let privateKey = "root-ca.key"
    }

    private let directory: URL
    private let lock = NSLock()

    /// 进程内缓存。磁盘读一次几毫秒，但代理每次启动都要用，没必要反复读。
    private var cached: Material?

    /// - Parameter directory: 证书存放目录。开放出来是为了让单测用独立目录，
    ///   避免污染真实的那一份。
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("CertificateAuthority", isDirectory: true)
    }

    // MARK: - 装载

    /// 拿到可用的根证书。没有就生成一份；存的那份坏了就重来。
    func loadOrCreate() throws -> Material {
        lock.lock()
        defer { lock.unlock() }

        if let cached { return cached }

        let stored: Material?
        do {
            stored = try loadStored()
        } catch {
            // **读不到不等于没有。** 这里必须抛出去而不是当作「没有」——
            // 当作没有就会生成一份新的覆盖掉旧的，而设备里装的还是旧的那张，
            // 表现为「突然所有 HTTPS 都握手失败」，且用户不知道为什么。
            throw error
        }

        if let stored, CoreBridge.validateCA(certificate: stored.certificate,
                                             privateKey: stored.privateKey) {
            cached = stored
            return stored
        }

        if stored != nil {
            // 文件在但内容对不上（被截断、被别的工具改过）—— 只能重来。
            AppLog.warn("证书", "已保存的根证书无法通过校验，将重新生成")
        }

        AppLog.info("证书", "没有可用的根证书，开始生成")
        let material = try generate()
        try persist(material)
        cached = material
        AppLog.info("证书", "根证书已就绪", details: ["dir": directory.lastPathComponent])
        return material
    }

    /// 重建根证书。
    ///
    /// **调用方必须先向用户二次确认** —— 旧 CA 作废之后，设备里已经装好的那张
    /// 根证书不再能签出被信任的叶子，必须重新走一遍「下载 → 安装 → 打开信任开关」。
    @discardableResult
    func rebuild() throws -> Material {
        lock.lock()
        defer { lock.unlock() }

        let material = try generate()
        try persist(material)
        cached = material
        AppLog.warn("证书", "根证书已重建，设备中旧的那张需要重新安装并重新信任")
        return material
    }

    /// 丢弃进程内缓存（磁盘上的那份不动）。
    ///
    /// 供「关闭代理服务」后释放内存用 —— 私钥留在内存里没有收益。
    func discardCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    /// 是否已经生成并保存过。
    var hasStoredMaterial: Bool {
        lock.lock()
        defer { lock.unlock() }
        if cached != nil { return true }
        // `try?` 会把嵌套可选拍平，所以这里比的是「取到没取到」，
        // 不能写成 `guard let ... != nil`（那会恒为真）。
        return (try? loadStored()) != nil
    }

    // MARK: - 生成

    private func generate() throws -> Material {
        guard let pair = CoreBridge.generateCA() else {
            AppLog.error("证书", "Core 未能生成根证书")
            throw Failure.generationFailed
        }
        // 生成出来立刻自校验一次：Go 侧理论上是可信的，但「拿到的证书和私钥
        // 到底能不能配成一对」如果不在这一步钉死，问题会在几十秒后以
        // 「代理 TLS 握手莫名其妙失败」的形态浮现，排查成本高得多。
        guard CoreBridge.validateCA(certificate: pair.certificate,
                                    privateKey: pair.privateKey) else {
            AppLog.error("证书", "生成的根证书未通过自校验")
            throw Failure.generationFailed
        }
        return Material(certificate: pair.certificate, privateKey: pair.privateKey)
    }

    // MARK: - 磁盘

    private var certificateURL: URL { directory.appendingPathComponent(File.certificate) }
    private var privateKeyURL: URL { directory.appendingPathComponent(File.privateKey) }

    /// 读已保存的那一份。文件不存在返回 `nil`；读失败抛错。
    private func loadStored() throws -> Material? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: certificateURL.path),
              manager.fileExists(atPath: privateKeyURL.path) else {
            return nil
        }

        do {
            let certificate = try String(contentsOf: certificateURL, encoding: .utf8)
            let privateKey = try String(contentsOf: privateKeyURL, encoding: .utf8)
            return Material(certificate: certificate, privateKey: privateKey)
        } catch {
            AppLog.error("证书", "读取已保存的根证书失败", details: [
                "error": error.localizedDescription,
            ])
            throw Failure.storageFailed
        }
    }

    private func persist(_ material: Material) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            try write(material.certificate, to: certificateURL)
            try write(material.privateKey, to: privateKeyURL)
        } catch {
            AppLog.error("证书", "根证书写入失败", details: [
                "error": error.localizedDescription,
            ])
            throw Failure.storageFailed
        }
    }

    private func write(_ text: String, to url: URL) throws {
        // `.atomic` 保证不会出现「写了一半」的文件 —— 半份 PEM 会让下次启动
        // 走到「内容对不上」那条路，进而重新生成一份新的 CA。
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
