import Foundation
import SQLite3

/// 会话名（卡片上显示的那个名字）的权威来源。
///
/// 之前卡片直接拿 `cwd` 的最后一段当名字，于是所有 WorkBuddy 会话都显示成
/// `2026-11-21-12-16-41` 这种工作区目录名 —— 同一个项目目录下的几个会话长得一模一样，
/// 根本分不出谁是谁。真正的会话名有三处，按可信度排：
///
///   1. `sessions.custom_title`：用户在应用里手动改过的名字，最高优先
///   2. 会话日志里的 `ai-title` 条目：应用自动生成，随日志增量解析（见 WorkBuddyAdapter），
///      最实时，但只在会话开头写一次，长会话的尾部窗口读不到
///   3. `sessions.title`：应用自动生成的标题，自动化会话（每日简报、签到）也有
///
/// 本类负责 1 和 3：一次只读全表读进内存（几百行，毫秒级），之后按 sessionId 查表，
/// 15 秒刷一次。日志里读不到名字时（长会话 / 自动化会话）靠它兜底。
///
/// WorkBuddy 正开着，WAL 模式下并发只读是安全的；库不存在或正在迁移就静默跳过，
/// 卡片退回工作区名，不影响状态刷新。
final class SessionTitles {
    static let shared = SessionTitles()

    /// 库里标题更新得慢，15 秒刷一次足够
    private let ttl: TimeInterval = 15

    private struct Tables {
        /// 用户改过的名字
        var custom: [String: String] = [:]
        /// 应用自动生成的标题
        var auto: [String: String] = [:]
        var loadedAt: TimeInterval = 0
    }

    private let dbURL: URL
    private var tables = Tables()
    private let lock = NSLock()

    init(dbURL: URL? = nil) {
        self.dbURL = dbURL ?? Paths.home.appendingPathComponent(".workbuddy/workbuddy.db")
    }

    /// 解析一个会话该叫什么：用户改过的 > 日志里的 ai-title > 库里自动标题
    func name(for sessionId: String, logTitle: String? = nil) -> String? {
        guard !sessionId.isEmpty else { return nil }
        refreshIfStale()

        lock.lock()
        let snapshot = tables
        lock.unlock()

        if let custom = snapshot.custom[sessionId] { return custom }
        if let logTitle, !logTitle.isEmpty { return logTitle }
        return snapshot.auto[sessionId]
    }

    // MARK: - 读库

    private func refreshIfStale() {
        lock.lock()
        let stale = tables.loadedAt == 0
            || Date().timeIntervalSince1970 - tables.loadedAt > ttl
        lock.unlock()
        guard stale else { return }
        reload()
    }

    private func reload() {
        // 先把时间戳推进，读失败（库还没建 / 正在迁移）也不至于每秒重试一次
        lock.lock()
        tables.loadedAt = Date().timeIntervalSince1970
        lock.unlock()

        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            if handle != nil { sqlite3_close(handle) }
            return
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT id, custom_title, title FROM sessions WHERE deleted_at IS NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let query = stmt else { return }
        defer { sqlite3_finalize(query) }

        var fresh = Tables()
        while sqlite3_step(query) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(query, 0) else { continue }
            let id = String(cString: idText)
            if let custom = Self.text(query, 1) { fresh.custom[id] = custom }
            if let auto = Self.text(query, 2) { fresh.auto[id] = auto }
        }
        fresh.loadedAt = Date().timeIntervalSince1970

        lock.lock()
        tables = fresh
        lock.unlock()
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
