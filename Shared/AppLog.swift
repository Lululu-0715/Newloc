import Foundation

/// 环形运行日志。
///
/// 只保留最近 N 条：诊断页要能「看图说话」，但不需要无限历史 ——
/// 上一版把缓冲设成 500 条已经够用，这里收紧到 200，滚动浏览更实际。
///
/// **为什么用锁而不是 actor**：Go 侧回调发生在任意线程，而且是**同步**调用回来
/// （`cgo` 直接调 Swift 闭包）。用 actor 的话每次写日志都要 `await`，
/// 顺序会被打乱，而日志的价值全在顺序上。
final class AppLog: @unchecked Sendable {

    static let shared = AppLog()

    enum Level: String, CaseIterable {
        case debug = "调试"
        case info = "信息"
        case warn = "警告"
        case error = "错误"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let category: String
        let message: String
        let details: [String: String]
    }

    private let capacity: Int
    private var storage: [Entry] = []
    private let lock = NSLock()

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    // MARK: - 写入

    func write(_ level: Level, _ category: String, _ message: String,
               details: [String: String] = [:]) {
        let entry = Entry(date: Date(), level: level, category: category,
                          message: message, details: details)

        lock.lock()
        storage.append(entry)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        lock.unlock()

        #if UI_TEST_HOOKS
        print("[\(level.rawValue)][\(category)] \(message) \(details)")
        #endif
    }

    static func debug(_ category: String, _ message: String, details: [String: String] = [:]) {
        shared.write(.debug, category, message, details: details)
    }

    static func info(_ category: String, _ message: String, details: [String: String] = [:]) {
        shared.write(.info, category, message, details: details)
    }

    static func warn(_ category: String, _ message: String, details: [String: String] = [:]) {
        shared.write(.warn, category, message, details: details)
    }

    static func error(_ category: String, _ message: String, details: [String: String] = [:]) {
        shared.write(.error, category, message, details: details)
    }

    // MARK: - 读取

    /// 当前全部日志（按时间正序）。
    var snapshot: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool { snapshot.isEmpty }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    /// 导出为可复制的纯文本。
    ///
    /// 带时间戳到毫秒 —— 排查「切后台再切回来」这类问题时，
    /// 秒级精度分不清两次校验的先后。
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        return snapshot.map { entry in
            var line = "[\(formatter.string(from: entry.date))][\(entry.level.rawValue)]"
                + "[\(entry.category)] \(entry.message)"
            if !entry.details.isEmpty {
                let pairs = entry.details.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ", ")
                line += " {\(pairs)}"
            }
            return line
        }
        .joined(separator: "\n")
    }
}
