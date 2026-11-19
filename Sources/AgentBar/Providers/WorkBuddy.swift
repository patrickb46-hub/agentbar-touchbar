import Foundation

/// WorkBuddy 桌面版 / CodeBuddy CLI 共用适配器。
///
/// 数据源：`~/.workbuddy/projects/<项目slug>/<sessionId>.jsonl`
/// 每行一个条目，关键字段：
///   type = message | reasoning | function_call | function_call_result | credit-usage
///   timestamp（毫秒）、sessionId、cwd、role（仅 message）
///
/// 状态推导（全部事件驱动，不靠静默时长猜）：
///   message(role=user)       → 回合打开
///   reasoning / function_call_result → 思考中
///   function_call 无 result  → 正在跑该工具
///   message(role=assistant)  → 回合关闭 → 完成
///   「等你确认」不看时长，看 ~/.workbuddy/audit-log 里的 ask-matched / needs-approval
final class WorkBuddyAdapter {
    let provider: String
    let root: URL

    /// 只有最近改动过的文件才值得每秒解析
    private var candidates: [URL] = []
    private var candidateStamp: TimeInterval = 0

    /// 用进程自己的时钟记「第一次看到这一轮」的时刻，
    /// 避免日志时间戳与系统时钟不同源导致耗时算成几小时。
    private var turnClock: [String: (key: Int64, at: TimeInterval)] = [:]

    init(provider: String = "workbuddy-desktop",
         root: URL = Paths.home.appendingPathComponent(".workbuddy/projects", isDirectory: true)) {
        self.provider = provider
        self.root = root
    }

    func available() -> Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    private func refreshCandidates(now: Date) {
        if now.timeIntervalSince1970 - candidateStamp < 8, !candidates.isEmpty { return }
        candidateStamp = now.timeIntervalSince1970

        var found: [URL] = []
        let cutoff = now.addingTimeInterval(-12 * 3600)
        for projectDir in FileUtil.subdirs(in: root) {
            for file in FileUtil.files(in: projectDir, matching: "jsonl") {
                if FileUtil.mtime(file) > cutoff { found.append(file) }
            }
        }
        candidates = found
    }

    func scan(now: Date = Date()) -> [AgentSnapshot] {
        guard available() else { return [] }
        refreshCandidates(now: now)

        var out: [AgentSnapshot] = []
        for file in candidates {
            let age = now.timeIntervalSince(FileUtil.mtime(file))
            if age > 3 * 3600 { continue }
            if let snap = parse(file: file, now: now) { out.append(snap) }
        }
        return out
    }

    // MARK: - 单文件解析

    private struct Parsed {
        var sessionId = ""
        var cwd: String?
        var lastUserMs: Double?
        var lastAssistantMs: Double?
        var lastEntryMs: Double = 0
        var turnOpen = false
        var pending: [String: (tool: String, ts: Double)] = [:]
    }

    private func parse(file: URL, now: Date) -> AgentSnapshot? {
        let objs = JSONLTail.objects(file, maxBytes: 2 * 1024 * 1024)
        guard !objs.isEmpty else { return nil }

        var p = Parsed()
        for obj in objs {
            let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
            if let sid = obj["sessionId"] as? String, !sid.isEmpty { p.sessionId = sid }
            if let cwd = obj["cwd"] as? String, !cwd.isEmpty { p.cwd = cwd }
            if ts > p.lastEntryMs { p.lastEntryMs = ts }

            switch obj["type"] as? String {
            case "message":
                switch obj["role"] as? String {
                case "user":
                    p.lastUserMs = ts
                    p.pending.removeAll()
                    p.turnOpen = true
                case "assistant":
                    p.lastAssistantMs = ts
                    p.turnOpen = false
                default:
                    break
                }
            case "function_call":
                let callId = (obj["callId"] as? String) ?? UUID().uuidString
                let name = (obj["name"] as? String) ?? "tool"
                p.pending[callId] = (name, ts)
            case "function_call_result":
                if let callId = obj["callId"] as? String { p.pending.removeValue(forKey: callId) }
            case "session-meta":
                if p.cwd == nil, let meta = obj["meta"] as? [String: Any] {
                    p.cwd = meta["cwd"] as? String
                }
            default:
                break
            }
        }

        guard p.lastEntryMs > 0 else { return nil }
        let nowMsD = now.timeIntervalSince1970 * 1000
        if nowMsD - p.lastEntryMs > 3 * 3600 * 1000 { return nil }

        // 长会话的 user 消息可能落在尾部窗口之外，单独回扫一次
        if p.lastUserMs == nil {
            p.lastUserMs = JSONLTail.lastUserTimestamp(file)
        }

        let sessionId = p.sessionId.isEmpty
            ? file.deletingPathExtension().lastPathComponent
            : p.sessionId

        // 到底有没有在等你，以应用自己的审计日志为准
        let audit = AuditLog.waitingApproval(sessionId: sessionId)
        let pendingTool = p.pending.max { $0.value.ts < $1.value.ts }

        var phase: Phase
        var tool: String?
        if audit.isWaiting {
            phase = .waitingApproval
            tool = pendingTool?.value.tool
        } else if let pending = pendingTool {
            phase = .tool
            tool = pending.value.tool
        } else if (nowMsD - p.lastEntryMs) < 2_000 {
            // 实测：干活时 assistant 消息后 0.1 秒内必有下一条，
            // 所以安静 2 秒就足以确认这一轮真的结束了。
            phase = .thinking
        } else if p.lastAssistantMs != nil, (nowMsD - p.lastEntryMs) < 120_000 {
            phase = .done
        } else {
            phase = .idle
        }

        if phase == .idle { return nil }

        // 本轮起点：用进程时钟记第一次观察时间
        let turnKey = Int64(p.lastUserMs ?? 0)
        var startedAt: Int64?
        if phase != .done {
            if let cached = turnClock[sessionId], cached.key == turnKey {
                startedAt = Int64(cached.at * 1000)
            } else {
                turnClock[sessionId] = (turnKey, now.timeIntervalSince1970)
                startedAt = Int64(now.timeIntervalSince1970 * 1000)
            }
        } else {
            turnClock[sessionId] = nil
        }

        // 本轮耗时：两端都取日志里的时间戳，天然同源
        var durationMs: Int64?
        if phase == .done, let user = p.lastUserMs, let done = p.lastAssistantMs, done >= user {
            durationMs = Int64(done - user)
        }

        let project = (p.cwd.map { ($0 as NSString).lastPathComponent })
            ?? file.deletingLastPathComponent().lastPathComponent
        let jump = "workbuddy://chat/"
            + (sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)

        return AgentSnapshot(
            provider: provider,
            sessionId: sessionId,
            project: project.isEmpty ? provider : project,
            cwd: p.cwd,
            phase: phase,
            tool: tool,
            note: audit.isWaiting ? audit.reason : nil,
            turnStartedAt: startedAt,
            updatedAt: Int64(p.lastEntryMs),
            jumpUrl: jump,
            durationMs: durationMs
        )
    }

    // MARK: - 今日累计

    func todayStats(now: Date = Date()) -> TodayStats {
        guard available() else { return TodayStats() }
        let cal = Calendar.current
        var stats = TodayStats()
        var tokens = 0
        var credits = 0.0

        for projectDir in FileUtil.subdirs(in: root) {
            for file in FileUtil.files(in: projectDir, matching: "jsonl") {
                guard cal.isDateInToday(FileUtil.mtime(file)) else { continue }
                var turnStart: Double?
                for obj in JSONLTail.allObjects(file) {
                    let ts = (obj["timestamp"] as? NSNumber)?.doubleValue ?? 0
                    switch obj["type"] as? String {
                    case "message":
                        if (obj["role"] as? String) == "user" {
                            stats.turns += 1
                            turnStart = ts
                        } else if (obj["role"] as? String) == "assistant", let start = turnStart {
                            stats.seconds += max(0, (ts - start) / 1000)
                            turnStart = nil
                        }
                    case "credit-usage":
                        if let pd = obj["providerData"] as? [String: Any] {
                            credits += (pd["credit"] as? NSNumber)?.doubleValue ?? 0
                            tokens += TokenHarvest.harvest(pd)
                        }
                    default:
                        break
                    }
                }
            }
        }

        stats.tokens = tokens > 0 ? tokens : nil
        stats.credits = credits
        return stats
    }
}
