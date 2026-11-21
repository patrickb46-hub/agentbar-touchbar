import Foundation

/// 读 WorkBuddy 的安全审计日志，判断「现在是不是真的卡在等你确认」。
///
/// 事件序列（实测）：
///   <scope>.ask-matched      命中规则，弹窗问你
///   <scope>.needs-approval   进入待确认
///   <scope>.approved / auto-approved / security-review.sandbox.final-allow  已放行
///
/// 所以：某个 toolCallId 的**最后一条**事件如果是 ask-matched / needs-approval，
/// 就是真的在等人；一旦出现 approved 之类的放行事件就不再是。
///
/// 性能：把「每个会话的最后一条事件」做成一张表，只在审计文件真的有追加时增量更新。
/// 原来每个会话、每个刷新周期都要把 2～3 个日志文件的尾部（256 KB）重新读一遍。
enum AuditLog {

    /// 目录可用 AGENTBAR_AUDIT_DIR 覆盖，方便用夹具测试判定逻辑
    private static var logDir: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTBAR_AUDIT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return Paths.home.appendingPathComponent(".workbuddy/audit-log", isDirectory: true)
    }
    private static var spoolDir: URL { logDir.appendingPathComponent("spool", isDirectory: true) }

    struct Waiting {
        var isWaiting: Bool
        var since: Int64?      // 首次 ask 的时间（毫秒）
        var reason: String?    // 例如 file-safety
    }

    private struct Latest {
        var ts: Double
        var type: String
    }

    private static let lock = NSLock()
    private static var followers: [String: (stamp: FileStamp, follower: TailFollower)] = [:]
    private static var latest: [String: Latest] = [:]
    private static var fileList: [URL] = []
    private static var fileListAt: TimeInterval = 0
    private static var lastRefresh: TimeInterval = 0

    static func waitingApproval(sessionId: String) -> Waiting {
        refresh()
        lock.lock()
        let hit = latest[sessionId]
        lock.unlock()

        guard let hit else { return Waiting(isWaiting: false, since: nil, reason: nil) }
        let askingSuffixes = ["ask-matched", "needs-approval"]
        let isAsking = askingSuffixes.contains { hit.type.hasSuffix($0) }
        return Waiting(isWaiting: isAsking,
                       since: isAsking ? Int64(hit.ts) : nil,
                       reason: isAsking ? hit.type.split(separator: ".").first.map(String.init) : nil)
    }

    static func invalidate() {
        lock.lock()
        followers.removeAll(); latest.removeAll(); fileList.removeAll()
        fileListAt = 0; lastRefresh = 0
        lock.unlock()
    }

    // MARK: - 增量刷新

    private static func refresh() {
        let now = Date().timeIntervalSince1970
        // 50 ms 内重复调用不再看盘（同一周期内多个会话都会来问）
        if now - lastRefresh < 0.05 { return }
        lastRefresh = now

        if now - fileListAt > 1 || fileList.isEmpty {
            fileListAt = now
            fileList = locateFiles()
        }
        guard !fileList.isEmpty else { return }

        for file in fileList {
            let stamp = FileStamp.read(file)
            guard stamp.size > 0 else { continue }
            let path = file.path

            lock.lock()
            let existing = followers[path]
            lock.unlock()

            if var entry = existing, stamp.size >= entry.stamp.size {
                if stamp.size == entry.stamp.size { continue }
                let (lines, truncated) = entry.follower.read(url: file, size: stamp.size)
                if !truncated {
                    for line in lines {
                        if let obj = JSONLTail.parseLine(line) { ingest(obj) }
                    }
                } else {
                    rescan(file, stamp: stamp)
                    continue
                }
                entry.stamp = stamp
                lock.lock(); followers[path] = entry; lock.unlock()
            } else {
                rescan(file, stamp: stamp)
            }
        }
    }

    private static func rescan(_ file: URL, stamp: FileStamp) {
        let follower = TailFollower()
        follower.reset(to: stamp.size)
        // 只回看尾部 256 KB，和以前一致
        for obj in JSONLTail.objects(file, maxBytes: 256 * 1024) { ingest(obj) }
        lock.lock()
        followers[file.path] = (stamp, follower)
        lock.unlock()
    }

    private static func ingest(_ obj: [String: Any]) {
        guard let session = obj["sessionId"] as? String,
              let type = obj["eventType"] as? String else { return }
        let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
        lock.lock()
        if let old = latest[session], old.ts > ts {
            lock.unlock()
            return
        }
        latest[session] = Latest(ts: ts, type: type)
        lock.unlock()
    }

    private static func locateFiles() -> [URL] {
        var files: [URL] = []
        if let spool = try? FileManager.default.contentsOfDirectory(
            at: spoolDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) {
            files += spool.filter { $0.pathExtension == "jsonl" }
        }
        // 跨零点也读得到：今天 + 昨天
        for offset in 0...1 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let dated = logDir.appendingPathComponent(ISODate.day(day) + ".jsonl")
            if FileManager.default.fileExists(atPath: dated.path) { files.append(dated) }
        }
        return files
    }
}
