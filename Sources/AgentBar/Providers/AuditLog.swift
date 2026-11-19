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

    private static var cache: [String: (result: Waiting, at: TimeInterval)] = [:]
    private static let cacheTTL: TimeInterval = 1.0

    static func waitingApproval(sessionId: String) -> Waiting {
        let now = Date().timeIntervalSince1970
        if let cached = cache[sessionId], now - cached.at < cacheTTL { return cached.result }

        let result = compute(sessionId: sessionId)
        cache[sessionId] = (result, now)
        return result
    }

    static func invalidate() { cache.removeAll() }

    private static func compute(sessionId: String) -> Waiting {
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

        guard !files.isEmpty else { return Waiting(isWaiting: false, since: nil, reason: nil) }

        // 只保留最新的一条事件
        var latestTs: Double = 0
        var latestType: String?
        var latestReason: String?

        for file in files {
            for obj in JSONLTail.objects(file, maxBytes: 256 * 1024) {
                guard (obj["sessionId"] as? String) == sessionId else { continue }
                let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
                guard ts >= latestTs else { continue }
                latestTs = ts
                latestType = obj["eventType"] as? String
                latestReason = latestType?.split(separator: ".").first.map(String.init)
            }
        }

        guard let type = latestType else { return Waiting(isWaiting: false, since: nil, reason: nil) }

        let askingSuffixes = ["ask-matched", "needs-approval"]
        let isAsking = askingSuffixes.contains { type.hasSuffix($0) }

        return Waiting(isWaiting: isAsking,
                       since: isAsking ? Int64(latestTs) : nil,
                       reason: isAsking ? latestReason : nil)
    }
}
